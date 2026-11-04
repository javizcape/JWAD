#requires -Version 5.1
<#
JWAD - Windows App Deployer (x64)
Compatibilidad objetivo: Windows 10/11 x64, Windows PowerShell 5.1 y PowerShell 7+
Ejecucion recomendada: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\JWAD_Resilient.ps1

Seguridad:
- No eleva privilegios re-descargando y ejecutando el script remoto.
- Winget es el origen primario; no es requisito para continuar.
- Los orígenes directos están declarados explícitamente por aplicación.
- GitHub API se prefiere a HTML; HTML solo busca assets dentro del repositorio indicado.
- Si GitHub publica digest SHA-256, se valida antes de ejecutar el instalador.
- Los códigos de salida desconocidos nunca se convierten en éxito.
#>

[CmdletBinding()]
param(
    [string]$ReportPath = ''
)

Set-StrictMode -Version 2.0
$script:OriginalErrorActionPreference = $ErrorActionPreference
$script:OriginalProgressPreference = $ProgressPreference
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Version = '4.0'
$script:RunStarted = Get-Date
$script:Timer = [System.Diagnostics.Stopwatch]::StartNew()
$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('JWAD-' + [Guid]::NewGuid().ToString('N'))
$script:Results = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$script:Hardware = [ordered]@{
    fabricante = 'Desconocido'
    modelo = 'Desconocido'
    procesador = 'Desconocido'
    memoria_ram_total_gb = 0
    uso_actual_ram_porcentaje = 0
    almacenamiento_total_gb = 0
    uso_actual_almacenamiento_porcentaje = 0
    temperatura_termica_wmi_c = $null
}
$script:FatalError = $null
$script:WingetPath = $null

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) {
        $desktop = [IO.Path]::GetTempPath()
    }
    $ReportPath = Join-Path $desktop 'Reporte_Despliegue_JWAD.json'
}
$script:ReportPath = $ReportPath

# Windows PowerShell 5.1/.NET Framework: añade TLS 1.2 sin eliminar protocolos presentes.
if ($PSVersionTable.PSVersion.Major -le 5) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Write-JWADBanner {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host '       JWAD - WINDOWS APP DEPLOYER' -ForegroundColor Cyan
    Write-Host ('                   v' + $script:Version) -ForegroundColor DarkCyan
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Add-JWADResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSObject]$Result)
    [System.Threading.Monitor]::Enter($script:Results.SyncRoot)
    try { [void]$script:Results.Add($Result) }
    finally { [System.Threading.Monitor]::Exit($script:Results.SyncRoot) }
}

function Save-JWADReport {
    [CmdletBinding()]
    param()
    $tempReport = $null
    try {
        [System.Threading.Monitor]::Enter($script:Results.SyncRoot)
        try { $resultSnapshot = @($script:Results.ToArray()) }
        finally { [System.Threading.Monitor]::Exit($script:Results.SyncRoot) }

        $report = [ordered]@{
            version = $script:Version
            fecha_inicio = $script:RunStarted.ToString('o')
            fecha_reporte = (Get-Date).ToString('o')
            equipo = [ordered]@{
                fabricante = $script:Hardware.fabricante
                modelo = $script:Hardware.modelo
                procesador = $script:Hardware.procesador
                memoria_ram_total_gb = $script:Hardware.memoria_ram_total_gb
                uso_actual_ram_porcentaje = $script:Hardware.uso_actual_ram_porcentaje
                almacenamiento_total_gb = $script:Hardware.almacenamiento_total_gb
                uso_actual_almacenamiento_porcentaje = $script:Hardware.uso_actual_almacenamiento_porcentaje
                temperatura_termica_wmi_c = $script:Hardware.temperatura_termica_wmi_c
            }
            tiempo_transcurrido_segundos = [Math]::Round($script:Timer.Elapsed.TotalSeconds, 2)
            resultado_aplicaciones = $resultSnapshot
            error_fatal = $script:FatalError
        }
        $json = ConvertTo-Json -InputObject $report -Depth 8
        $parent = Split-Path -Parent $script:ReportPath
        if ([string]::IsNullOrWhiteSpace($parent)) {
            $script:ReportPath = Join-Path (Get-Location).Path $script:ReportPath
            $parent = Split-Path -Parent $script:ReportPath
        }
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $tempReport = $script:ReportPath + '.tmp'
        Set-Content -LiteralPath $tempReport -Value $json -Encoding UTF8 -Force
        Move-Item -LiteralPath $tempReport -Destination $script:ReportPath -Force
    } catch {
        Write-Warning ('No se pudo guardar el reporte: ' + $_.Exception.Message)
        if ($tempReport -and (Test-Path -LiteralPath $tempReport)) {
            Remove-Item -LiteralPath $tempReport -Force -ErrorAction SilentlyContinue
        }
    }
}

function Update-JWADEnvironment {
    [CmdletBinding()]
    param()
    $combined = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($scope in @('Machine', 'User')) {
        try {
            $envVars = [Environment]::GetEnvironmentVariables($scope)
            $pathValue = [string]$envVars['Path']
            foreach ($part in ($pathValue -split ';')) {
                $candidate = $part.Trim()
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $key = $candidate.ToLowerInvariant()
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        [void]$combined.Add($candidate)
                    }
                }
            }
        } catch { }
    }
    foreach ($part in ($env:Path -split ';')) {
        $candidate = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $key = $candidate.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [void]$combined.Add($candidate)
            }
        }
    }
    $env:Path = $combined -join ';'
}

function Get-JWADWingetPath {
    [CmdletBinding()]
    param()
    Update-JWADEnvironment
    $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }
    $command = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $aliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $aliasPath) { return $aliasPath }
    }
    return $null
}

function Invoke-JWADProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ArgumentList = '',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
    )
    $process = $null
    try {
        $startParameters = @{
            FilePath = $FilePath
            PassThru = $true
            WindowStyle = 'Hidden'
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($ArgumentList)) {
            $startParameters.ArgumentList = $ArgumentList
        }
        $process = Start-Process @startParameters
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw ('TIMEOUT: proceso superó ' + $TimeoutSeconds + ' segundos: ' + $FilePath)
        }
        $process.Refresh()
        return [int]$process.ExitCode
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Invoke-JWADWingetInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$')][string]$Id)

    $winget = Get-JWADWingetPath
    if (-not $winget) { throw 'Winget no está disponible en este perfil de usuario.' }

    $common = '--id "' + $Id + '" --exact --silent --accept-package-agreements --accept-source-agreements --source winget --architecture x64'
    $upgradeCode = Invoke-JWADProcess -FilePath $winget -ArgumentList ('upgrade ' + $common) -TimeoutSeconds 600

    if ($upgradeCode -eq 0) { return 'INSTALLED' }
    if ($upgradeCode -eq 3010) { return 'INSTALLED_REINICIO_PENDIENTE' }

    # HRESULT documentado: APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE.
    # Puede significar que no hay versión superior o que el paquete no está instalado;
    # en ambos casos se intenta install para resolver el estado sin interpretar texto tabular.
    if ($upgradeCode -eq -1978335189) {
        $installCode = Invoke-JWADProcess -FilePath $winget -ArgumentList ('install ' + $common) -TimeoutSeconds 600
        if ($installCode -eq 0) { return 'INSTALLED' }
        if ($installCode -eq 3010) { return 'INSTALLED_REINICIO_PENDIENTE' }
        # HRESULT documentado: APPINSTALLER_CLI_ERROR_INSTALL_ALREADY_INSTALLED.
        if ($installCode -eq -1978334963) { return 'YA_INSTALADO' }
        throw ('Winget install devolvió el código ' + $installCode)
    }

    # Algunos clientes devuelven INSTALL_ALREADY_INSTALLED al consultar/installar un paquete.
    if ($upgradeCode -eq -1978334963) { return 'YA_INSTALADO' }
    throw ('Winget upgrade devolvió el código ' + $upgradeCode)
}

function Install-JWADWingetBootstrapper {
    [CmdletBinding()]
    param()
    $existing = Get-JWADWingetPath
    if ($existing) {
        $script:WingetPath = $existing
        Write-Host '[OK] Winget detectado.' -ForegroundColor Green
        return $true
    }

    Write-Host '[*] Winget no está disponible. Bootstrapper App Installer opcional...' -ForegroundColor Yellow
    if (-not (Get-Command -Name 'Add-AppxPackage' -ErrorAction SilentlyContinue)) {
        Write-Warning 'Add-AppxPackage no está disponible. Se omite el bootstrapper y se usarán los orígenes alternativos.'
        return $false
    }

    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $files = [System.Collections.Generic.List[string]]::new()
    try {
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        # Descarga dependencias, pero las registra junto con el bundle para que AppX resuelva
        # el conjunto en una única operación. Un fallo aquí no bloquea los fallbacks del catálogo.
        $dependencyDefinitions = @(
            [PSCustomObject]@{
                Name = 'VCLibs.appx'
                Url = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
                AllowedHosts = @('aka.ms', 'microsoft.com')
            },
            [PSCustomObject]@{
                Name = 'Microsoft.UI.Xaml.2.8.x64.appx'
                Url = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'
                AllowedHosts = @('github.com')
            }
        )
        $dependencyPaths = [System.Collections.Generic.List[string]]::new()
        foreach ($dependency in $dependencyDefinitions) {
            $path = Join-Path $script:TempRoot $dependency.Name
            try {
                Invoke-JWADDownload -Uri ([uri]$dependency.Url) -Destination $path -AllowedHosts $dependency.AllowedHosts
                [void]$files.Add($path)
                [void]$dependencyPaths.Add($path)
            } catch {
                Write-Warning ('No se pudo preparar ' + $dependency.Name + ': ' + $_.Exception.Message)
            }
        }

        $bundlePath = Join-Path $script:TempRoot 'Microsoft.DesktopAppInstaller.msixbundle'
        $bundleUrl = 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        Invoke-JWADDownload -Uri ([uri]$bundleUrl) -Destination $bundlePath -AllowedHosts @('github.com')
        [void]$files.Add($bundlePath)

        if ($dependencyPaths.Count -gt 0) {
            Add-AppxPackage -Path $bundlePath -DependencyPath $dependencyPaths.ToArray() -ErrorAction Stop
        } else {
            Add-AppxPackage -Path $bundlePath -ErrorAction Stop
        }
        Update-JWADEnvironment
        $script:WingetPath = Get-JWADWingetPath
        if ($script:WingetPath) {
            Write-Host '[OK] Winget quedó disponible tras instalar App Installer.' -ForegroundColor Green
            return $true
        }
        Write-Warning 'App Installer se registró, pero winget.exe no quedó disponible en este perfil.'
        return $false
    } catch {
        Write-Warning ('Bootstrapper no disponible en este Windows: ' + $_.Exception.Message)
        return $false
    } finally {
        foreach ($file in $files) {
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
        $ProgressPreference = $previousProgress
    }
}

function Get-JWADResponseHeader {
    [CmdletBinding()]
    param([object]$Response, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Response) { return $null }
    try {
        $headers = $Response.Headers
        if ($headers -is [System.Net.WebHeaderCollection]) { return [string]$headers.Get($Name) }
        return [string]$headers[$Name]
    } catch { return $null }
}

function Get-JWADHttpStatus {
    [CmdletBinding()]
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

function Get-JWADGitHubRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repo)

    $apiUrl = 'https://api.github.com/repos/' + $Repo + '/releases/latest'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'JWAD-Windows-App-Deployer/' + $script:Version
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $lastError = $null

    for ($attempt = 0; $attempt -le 2; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing -TimeoutSec 35 -ErrorAction Stop
        } catch {
            $lastError = $_
            $response = $_.Exception.Response
            $status = Get-JWADHttpStatus -ErrorRecord $_
            $retryAfter = Get-JWADResponseHeader -Response $response -Name 'Retry-After'
            $remaining = Get-JWADResponseHeader -Response $response -Name 'X-RateLimit-Remaining'
            $reset = Get-JWADResponseHeader -Response $response -Name 'X-RateLimit-Reset'
            $transient = ($status -eq 403 -or $status -eq 429 -or $status -eq 500 -or $status -eq 502 -or $status -eq 503 -or $status -eq 504)
            if (-not $transient -or $attempt -ge 2) { break }

            $delay = 0
            $parsedDelay = 0
            if (-not [string]::IsNullOrWhiteSpace($retryAfter) -and [int]::TryParse($retryAfter, [ref]$parsedDelay)) {
                $delay = $parsedDelay
            } elseif ($remaining -eq '0' -and -not [string]::IsNullOrWhiteSpace($reset)) {
                try {
                    $resetDate = [DateTimeOffset]::FromUnixTimeSeconds([long]$reset).UtcDateTime
                    $delay = [int][Math]::Ceiling(($resetDate - [DateTime]::UtcNow).TotalSeconds)
                } catch { $delay = 60 }
            } else {
                # GitHub recomienda esperar al menos un minuto cuando faltan cabeceras de rate-limit.
                $delay = [int][Math]::Min(120, (60 * [Math]::Pow(2, $attempt)))
            }
            $delay = [Math]::Max(1, $delay)
            if ($delay -gt 120) {
                throw ('Rate limit de GitHub: Retry-After/reset exige esperar ' + $delay + ' s; se omite la API y se intenta el HTML restringido sin reintentar antes de tiempo.')
            }
            Write-Warning ('GitHub API HTTP ' + $status + '. Reintento ' + ($attempt + 1) + '/2 en ' + $delay + ' s.')
            Start-Sleep -Seconds $delay
        }
    }

    throw ('GitHub API no disponible tras reintentos: ' + $lastError.Exception.Message)
}

function Test-JWADAllowedHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string[]]$AllowedHosts
    )
    if ($Uri.Scheme -ne 'https') { return $false }
    foreach ($hostName in $AllowedHosts) {
        if ($Uri.Host -ieq $hostName -or $Uri.Host.EndsWith('.' + $hostName, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-JWADGitHubAssetFromHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$AssetRegex
    )
    $pageUrl = 'https://github.com/' + $Repo + '/releases/latest'
    $page = Invoke-WebRequest -Uri $pageUrl -UseBasicParsing -TimeoutSec 35 -ErrorAction Stop
    $matches = [regex]::Matches([string]$page.Content, '(?is)href\s*=\s*["''](?<href>[^"''#]+)["'']')
    $assets = [System.Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $href = [System.Net.WebUtility]::HtmlDecode($match.Groups['href'].Value)
        try {
            if ($href.StartsWith('/')) { $uri = [System.Uri]::new('https://github.com' + $href) }
            else { $uri = [System.Uri]::new($href) }
        } catch { continue }
        if ($uri.Host -ine 'github.com') { continue }
        if ($uri.AbsolutePath -notmatch ('^/' + [regex]::Escape($Repo) + '/releases/download/')) { continue }
        $name = [IO.Path]::GetFileName($uri.AbsolutePath)
        if ($name -match $AssetRegex -and $name -match '(?i)\.(exe|msi)$') {
            [void]$assets.Add([PSCustomObject]@{
                Name = $name
                Uri = $uri.AbsoluteUri
                Version = 'HTML-latest'
                Digest = $null
                IntegritySource = 'HTTPS_HTML_SIN_DIGEST_API'
            })
        }
    }
    $unique = @($assets | Sort-Object -Property Name -Unique)
    if ($unique.Count -ne 1) {
        throw ('HTML de GitHub: se esperaba exactamente un asset x64 coincidente; encontrados: ' + $unique.Count)
    }
    return $unique[0]
}

function Get-JWADGitHubAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$AssetRegex
    )
    try {
        $release = Get-JWADGitHubRelease -Repo $Repo
        $assets = @($release.assets | Where-Object {
            $_.name -match $AssetRegex -and $_.name -match '(?i)\.(exe|msi)$'
        })
        if ($assets.Count -ne 1) {
            throw ('GitHub API: se esperaba exactamente un asset coincidente en ' + $Repo + '; encontrados: ' + $assets.Count)
        }
        $asset = $assets[0]
        $uri = [uri]$asset.browser_download_url
        if (-not (Test-JWADAllowedHost -Uri $uri -AllowedHosts @('github.com'))) {
            throw ('Host de descarga inesperado: ' + $uri.Host)
        }
        return [PSCustomObject]@{
            Name = [string]$asset.name
            Uri = $uri.AbsoluteUri
            Version = [string]$release.tag_name
            Digest = [string]$asset.digest
            IntegritySource = 'GITHUB_API'
        }
    } catch {
        Write-Warning ('API de Releases falló para ' + $Repo + '; activando parser HTML restringido: ' + $_.Exception.Message)
        return Get-JWADGitHubAssetFromHtml -Repo $Repo -AssetRegex $AssetRegex
    }
}

function Get-JWADPageAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$PageUri,
        [Parameter(Mandatory)][string]$AssetRegex,
        [Parameter(Mandatory)][string[]]$AllowedHosts
    )
    if (-not (Test-JWADAllowedHost -Uri $PageUri -AllowedHosts $AllowedHosts)) {
        throw ('Página de fallback fuera de la lista permitida: ' + $PageUri.Host)
    }
    $page = Invoke-WebRequest -Uri $PageUri.AbsoluteUri -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
    $matches = [regex]::Matches([string]$page.Content, '(?is)href\s*=\s*["''](?<href>[^"''#]+)["'']')
    $assets = [System.Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $href = [System.Net.WebUtility]::HtmlDecode($match.Groups['href'].Value)
        try {
            $uri = [System.Uri]::new($PageUri, $href)
        } catch { continue }
        if (-not (Test-JWADAllowedHost -Uri $uri -AllowedHosts $AllowedHosts)) { continue }
        $name = [IO.Path]::GetFileName($uri.AbsolutePath)
        if ($name -match $AssetRegex -and $name -match '(?i)\.(exe|msi)$') {
            [void]$assets.Add([PSCustomObject]@{
                Name = $name
                Uri = $uri.AbsoluteUri
                Version = 'latest-web-page'
                Digest = $null
                IntegritySource = 'HTTPS_OFFICIAL_PAGE_SIN_DIGEST'
            })
        }
    }
    $unique = @($assets | Sort-Object -Property Name -Unique)
    if ($unique.Count -ne 1) {
        throw ('Página oficial: se esperaba exactamente un instalador coincidente; encontrados: ' + $unique.Count)
    }
    return $unique[0]
}

function Invoke-JWADDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string[]]$AllowedHosts
    )
    if (-not (Test-JWADAllowedHost -Uri $Uri -AllowedHosts $AllowedHosts)) {
        throw ('URL no permitida: ' + $Uri.AbsoluteUri)
    }
    $response = Invoke-WebRequest -Uri $Uri.AbsoluteUri -OutFile $Destination -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
    $finalUri = $null
    try {
        $baseResponse = $response.BaseResponse
        if ($baseResponse -is [System.Net.Http.HttpResponseMessage]) {
            $finalUri = $baseResponse.RequestMessage.RequestUri
        } elseif ($baseResponse.ResponseUri) {
            $finalUri = [uri]$baseResponse.ResponseUri
        }
    } catch { }
    if ($finalUri) {
        $redirectHosts = @($AllowedHosts) + @('githubusercontent.com')
        if (-not (Test-JWADAllowedHost -Uri $finalUri -AllowedHosts $redirectHosts)) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw ('Redirección a host no permitido: ' + $finalUri.Host)
        }
    }
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -le 0) {
        throw 'Descarga vacía o inexistente.'
    }
}

function Invoke-JWADFallbackInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSObject]$Package)

    $asset = $null
    $allowedHosts = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$Package.GitHubRepo)) {
        $asset = Get-JWADGitHubAsset -Repo $Package.GitHubRepo -AssetRegex $Package.AssetRegex
        $allowedHosts = @('github.com')
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Package.FallbackPageUrl)) {
        $asset = Get-JWADPageAsset -PageUri ([uri]$Package.FallbackPageUrl) -AssetRegex $Package.AssetRegex -AllowedHosts $Package.AllowedHosts
        $allowedHosts = @($Package.AllowedHosts)
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Package.FallbackUrl)) {
        $asset = [PSCustomObject]@{
            Name = [string]$Package.FallbackFileName
            Uri = [string]$Package.FallbackUrl
            Version = 'latest-direct-url'
            Digest = [string]$Package.FallbackSha256
            IntegritySource = 'HTTPS_URL_CONFIGURADA'
        }
        $allowedHosts = @($Package.AllowedHosts)
    } else {
        throw 'SIN INFORMACIÓN: no hay un origen directo oficial validado para esta aplicación.'
    }

    $safeName = [IO.Path]::GetFileName([string]$asset.Name)
    if ([string]::IsNullOrWhiteSpace($safeName) -or $safeName -notmatch '(?i)\.(exe|msi)$') {
        throw ('Nombre de instalador no válido: ' + $asset.Name)
    }
    $downloadPath = Join-Path $script:TempRoot $safeName
    $downloadUri = [uri]$asset.Uri
    Invoke-JWADDownload -Uri $downloadUri -Destination $downloadPath -AllowedHosts $allowedHosts

    $integrity = [string]$asset.IntegritySource
    if (-not [string]::IsNullOrWhiteSpace([string]$asset.Digest)) {
        if ([string]$asset.Digest -notmatch '^sha256:([A-Fa-f0-9]{64})$') {
            throw 'El digest reportado por el origen no es SHA-256 válido.'
        }
        $expectedHash = ([string]$asset.Digest -replace '^sha256:', '').ToLowerInvariant()
        $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw 'SHA-256 no coincide con el digest publicado por GitHub.' }
        $integrity = 'SHA256_VERIFICADO_API'
    } else {
        $integrity = $integrity + '_SIN_SHA256_PUBLICADO'
    }

    # NotSigned se informa, pero un error real de verificación no se convierte en permiso.
    $authenticodeCommand = Get-Command -Name 'Get-AuthenticodeSignature' -ErrorAction SilentlyContinue
    if ($authenticodeCommand) {
        $signature = Get-AuthenticodeSignature -FilePath $downloadPath -ErrorAction Stop
        $signatureStatus = $signature.Status.ToString()
        if ($signatureStatus -notin @('Valid', 'NotSigned')) {
            throw ('Firma Authenticode rechazada o no verificable: ' + $signatureStatus)
        }
        if ($signatureStatus -eq 'Valid') {
            $integrity = $integrity + ';AUTHENTICODE_VALID'
        } elseif ($signature.Status.ToString() -eq 'NotSigned') {
            $integrity = $integrity + ';NOT_SIGNED'
        }
    } else {
        $integrity = $integrity + ';AUTHENTICODE_CMDLET_NO_DISPONIBLE'
    }

    $extension = [IO.Path]::GetExtension($downloadPath).ToLowerInvariant()
    if ($extension -eq '.msi') {
        $msiexecPath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
            $msiexecPath = Join-Path $env:SystemRoot 'Sysnative\msiexec.exe'
        }
        $exitCode = Invoke-JWADProcess -FilePath $msiexecPath -ArgumentList ('/i "' + $downloadPath + '" /qn /norestart') -TimeoutSeconds 600
    } else {
        $installerArguments = [string]$Package.FallbackArguments
        $exitCode = Invoke-JWADProcess -FilePath $downloadPath -ArgumentList $installerArguments -TimeoutSeconds 600
    }

    if ($exitCode -eq 0) {
        Update-JWADEnvironment
        return [PSCustomObject]@{ Estado = 'INSTALLED'; Version = [string]$asset.Version; Codigo = $exitCode; Integridad = $integrity }
    }
    if ($exitCode -eq 3010) {
        Update-JWADEnvironment
        return [PSCustomObject]@{ Estado = 'INSTALLED_REINICIO_PENDIENTE'; Version = [string]$asset.Version; Codigo = $exitCode; Integridad = $integrity }
    }
    throw ('Instalador directo devolvió código no aceptado: ' + $exitCode + '. Solo 0 y 3010 se consideran éxito.')
}

function New-JWADResult {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$State,
        [string]$Version = 'N/A',
        [double]$Seconds = 0,
        [string]$Source = 'N/A',
        [Nullable[int]]$ExitCode = $null,
        [string]$Integrity = 'N/A',
        [string]$ErrorMessage = $null
    )
    return [PSCustomObject]@{
        app_name = $Name
        estado = $State
        version_instalada = $Version
        tiempo_instalacion_segundos = [Math]::Round($Seconds, 2)
        fuente = $Source
        codigo_salida = $ExitCode
        integridad = $Integrity
        error_mensaje = $ErrorMessage
    }
}

function Install-JWADPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSObject]$Package)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $wingetError = $null
    Write-Host ('[*] ' + $Package.Name + ' | Winget: ' + $Package.WingetId) -ForegroundColor Cyan
    try {
        $wingetState = Invoke-JWADWingetInstall -Id $Package.WingetId
        $timer.Stop()
        Write-Host ('[OK] ' + $Package.Name + ' (' + $wingetState + ')') -ForegroundColor Green
        return (New-JWADResult -Name $Package.Name -State $wingetState -Version 'Gestionada por Winget' -Seconds $timer.Elapsed.TotalSeconds -Source 'WINGET' -ExitCode 0 -Integrity 'VALIDACION_WINGET')
    } catch {
        $wingetError = $_.Exception.Message
        Write-Warning ('Winget falló para ' + $Package.Name + ': ' + $wingetError)
    }

    Write-Host ('[*] Activando fallback para ' + $Package.Name + '...') -ForegroundColor Yellow
    try {
        $fallbackResult = Invoke-JWADFallbackInstall -Package $Package
        $timer.Stop()
        Write-Host ('[OK] ' + $Package.Name + ' mediante fallback (' + $fallbackResult.Estado + ')') -ForegroundColor Green
        return (New-JWADResult -Name $Package.Name -State $fallbackResult.Estado -Version $fallbackResult.Version -Seconds $timer.Elapsed.TotalSeconds -Source 'FALLBACK_DIRECTO' -ExitCode $fallbackResult.Codigo -Integrity $fallbackResult.Integridad -ErrorMessage ('Winget: ' + $wingetError))
    } catch {
        $timer.Stop()
        $fallbackError = $_.Exception.Message
        Write-Host ('[FALLO] ' + $Package.Name + ': ' + $fallbackError) -ForegroundColor Red
        return (New-JWADResult -Name $Package.Name -State 'FAILED' -Seconds $timer.Elapsed.TotalSeconds -Source 'WINGET+FALLBACK' -ErrorMessage ('Winget: ' + $wingetError + ' | Fallback: ' + $fallbackError))
    }
}

function Test-JWADDotNetFramework {
    [CmdletBinding()]
    param()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        $release = [int]$key.Release
        $state = if ($release -ge 528040) { 'YA_ACTUALIZADO' } else { 'DESACTUALIZADO' }
        $timer.Stop()
        return (New-JWADResult -Name '.NET Framework 4.8+' -State $state -Version ('Release ' + $release) -Seconds $timer.Elapsed.TotalSeconds -Source 'REGISTRO_LOCAL' -ExitCode 0)
    } catch {
        $timer.Stop()
        return (New-JWADResult -Name '.NET Framework 4.8+' -State 'FAILED' -Seconds $timer.Elapsed.TotalSeconds -Source 'REGISTRO_LOCAL' -ErrorMessage $_.Exception.Message)
    }
}

function Get-JWADTelemetry {
    [CmdletBinding()]
    param()
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($computer.Manufacturer) { $script:Hardware.fabricante = [string]$computer.Manufacturer }
        if ($computer.Model) { $script:Hardware.modelo = [string]$computer.Model }
        if ($processor -and $processor.Name) { $script:Hardware.procesador = ([string]$processor.Name).Trim() }

        $ramBytes = [double]$computer.TotalPhysicalMemory
        if ($ramBytes -gt 0) { $script:Hardware.memoria_ram_total_gb = [Math]::Round($ramBytes / 1GB, 2) }
        $ramTotalKb = [double]$os.TotalVisibleMemorySize
        $ramFreeKb = [double]$os.FreePhysicalMemory
        if ($ramTotalKb -gt 0) {
            $script:Hardware.uso_actual_ram_porcentaje = [Math]::Round((($ramTotalKb - $ramFreeKb) / $ramTotalKb) * 100, 2)
        }
        if ($disk -and [double]$disk.Size -gt 0) {
            $diskTotal = [double]$disk.Size
            $diskFree = [double]$disk.FreeSpace
            $script:Hardware.almacenamiento_total_gb = [Math]::Round($diskTotal / 1GB, 2)
            $script:Hardware.uso_actual_almacenamiento_porcentaje = [Math]::Round((($diskTotal - $diskFree) / $diskTotal) * 100, 2)
        }
    } catch {
        Write-Warning ('Telemetría CIM parcial/no disponible: ' + $_.Exception.Message)
    }

    # Esta clase puede no existir o no representar la temperatura del CPU en muchos equipos.
    try {
        $zones = Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop
        if ($zones) {
            $valid = @($zones | Where-Object { $_.CurrentTemperature -gt 0 })
            if ($valid.Count -gt 0) {
                $script:Hardware.temperatura_termica_wmi_c = [Math]::Round((([double]$valid[0].CurrentTemperature / 10) - 273.15), 2)
            }
        }
    } catch {
        $script:Hardware.temperatura_termica_wmi_c = $null
    }
}

function Show-JWADProgress {
    [CmdletBinding()]
    param([int]$Current, [int]$Total, [string]$Label)
    $width = 28
    $fraction = if ($Total -gt 0) { [Math]::Min(1, [Math]::Max(0, ($Current / [double]$Total))) } else { 0 }
    $filled = [int][Math]::Round($width * $fraction)
    $empty = $width - $filled
    $bar = ('#' * $filled) + ('.' * $empty)
    Write-Host ("[{0,2}/{1,2}] {2}" -f $Current, $Total, $Label) -ForegroundColor Cyan
    Write-Host ('[' + $bar + '] ' + [Math]::Round($script:Timer.Elapsed.TotalSeconds, 1) + ' s') -ForegroundColor DarkCyan
}

# Catálogo. Cada fallback se configura solo con un origen conocido; sin fallback se registra SIN INFORMACIÓN.
$packages = @(
    [PSCustomObject]@{
        Name = 'Visual C++ Redistributable x64'; WingetId = 'Microsoft.VCRedist.2015+.x64'
        GitHubRepo = ''; AssetRegex = ''; FallbackPageUrl = ''; AllowedHosts = @('aka.ms','microsoft.com')
        FallbackUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'; FallbackFileName = 'vc_redist.x64.exe'; FallbackSha256 = ''; FallbackArguments = '/install /quiet /norestart'
    },
    [PSCustomObject]@{
        Name = 'Java Runtime Environment 21 x64'; WingetId = 'EclipseAdoptium.Temurin.21.JRE'
        GitHubRepo = ''; AssetRegex = ''; FallbackPageUrl = ''; AllowedHosts = @('adoptium.net','github.com')
        FallbackUrl = 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jre/hotspot/normal/eclipse'; FallbackFileName = 'Temurin21JRE-x64.msi'; FallbackSha256 = ''; FallbackArguments = ''
    },
    [PSCustomObject]@{
        Name = '7-Zip x64'; WingetId = '7zip.7zip'
        GitHubRepo = 'ip7z/7zip'; AssetRegex = '(?i)^7z[0-9]+-x64\.exe$'; FallbackPageUrl = ''; AllowedHosts = @('github.com')
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = '/S'
    },
    [PSCustomObject]@{
        Name = 'Bulk Crap Uninstaller'; WingetId = 'Klocman.BulkCrapUninstaller'
        GitHubRepo = ''; AssetRegex = ''; FallbackPageUrl = ''; AllowedHosts = @()
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    },
    [PSCustomObject]@{
        Name = 'SumatraPDF x64'; WingetId = 'SumatraPDF.SumatraPDF'
        GitHubRepo = ''; AssetRegex = '(?i)^SumatraPDF-[0-9.]+-64-install\.exe$'; FallbackPageUrl = 'https://www.sumatrapdfreader.org/download-free-pdf-viewer'; AllowedHosts = @('sumatrapdfreader.org')
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = '-install -silent -all-users'
    },
    [PSCustomObject]@{
        Name = 'AB Download Manager'; WingetId = 'amir1376.ABDownloadManager'
        GitHubRepo = 'amir1376/ab-download-manager'; AssetRegex = '(?i)(windows|win)[-_].*(x64|x86_64|amd64).*\.exe$'; FallbackPageUrl = ''; AllowedHosts = @('github.com')
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = '/S'
    },
    [PSCustomObject]@{
        Name = 'WinRAR x64'; WingetId = 'RARLab.WinRAR'
        GitHubRepo = ''; AssetRegex = '(?i)^winrar-x64-[0-9]+\.exe$'; FallbackPageUrl = 'https://www.rarlab.com/download.htm'; AllowedHosts = @('rarlab.com')
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = '/S'
    },
    [PSCustomObject]@{
        Name = 'VLC Media Player x64'; WingetId = 'VideoLAN.VLC'
        GitHubRepo = ''; AssetRegex = '(?i)^vlc-[0-9.]+-win64\.exe$'; FallbackPageUrl = 'https://www.videolan.org/vlc/download-windows.html'; AllowedHosts = @('videolan.org')
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = '/S'
    },
    [PSCustomObject]@{
        Name = 'Google Chrome x64'; WingetId = 'Google.Chrome'
        GitHubRepo = ''; AssetRegex = ''; FallbackPageUrl = ''; AllowedHosts = @('google.com','dl.google.com')
        FallbackUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'; FallbackFileName = 'GoogleChromeEnterprise64.msi'; FallbackSha256 = ''; FallbackArguments = ''
    },
    [PSCustomObject]@{
        Name = 'Mozilla Firefox x64'; WingetId = 'Mozilla.Firefox'
        GitHubRepo = ''; AssetRegex = ''; FallbackPageUrl = ''; AllowedHosts = @('mozilla.org','mozilla.net','download.mozilla.org')
        FallbackUrl = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US'; FallbackFileName = 'FirefoxSetup-x64.exe'; FallbackSha256 = ''; FallbackArguments = '-ms'
    },
    [PSCustomObject]@{
        Name = 'Mullvad Browser x64'; WingetId = 'MullvadVPN.MullvadBrowser'
        GitHubRepo = 'mullvad/mullvad-browser'; AssetRegex = '(?i)^mullvad-browser-windows-x86_64-[0-9.]+\.exe$'; FallbackPageUrl = ''; AllowedHosts = @('github.com')
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = '/S'
    },
    [PSCustomObject]@{
        Name = 'Microsoft Edge x64'; WingetId = 'Microsoft.Edge'
        GitHubRepo = ''; AssetRegex = ''; FallbackPageUrl = ''; AllowedHosts = @()
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = ''
    },
    [PSCustomObject]@{
        Name = 'FlyPhotos x64'; WingetId = 'riyasy.FlyPhotos'
        GitHubRepo = 'riyasy/FlyPhotos'; AssetRegex = '(?i)^FlyPhotos.*x64.*\.msi$'; FallbackPageUrl = ''; AllowedHosts = @('github.com')
        FallbackUrl = ''; FallbackFileName = ''; FallbackSha256 = ''; FallbackArguments = ''
    }
)

try {
    Write-JWADBanner

    if ($env:OS -ne 'Windows_NT') { throw 'Este script solo puede ejecutarse en Windows.' }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
        throw 'Arquitectura no compatible: se requiere Windows x64 (AMD64).'
    }
    if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        throw 'Se requiere Windows PowerShell 5.1 o PowerShell 7+.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'Se requieren privilegios de Administrador. Ejecute el archivo local desde una consola elevada. No se volverá a descargar ni ejecutar el script remoto para elevarlo.'
    }

    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    Write-Host '[OK] Windows x64 y privilegios de administrador confirmados.' -ForegroundColor Green

    # Winget solo es un optimizador. Un bootstrapper imposible en LTSC no detiene el catálogo.
    [void](Install-JWADWingetBootstrapper)

    $step = 0
    $total = $packages.Count + 2
    $step++
    Show-JWADProgress -Current $step -Total $total -Label '.NET Framework 4.8+ (validación)'
    Add-JWADResult -Result (Test-JWADDotNetFramework)
    Save-JWADReport

    foreach ($package in $packages) {
        $step++
        Show-JWADProgress -Current $step -Total $total -Label $package.Name
        $result = Install-JWADPackage -Package $package
        Add-JWADResult -Result $result
        Save-JWADReport
    }

    $step++
    Show-JWADProgress -Current $step -Total $total -Label 'Telemetría local del equipo'
    Get-JWADTelemetry
} catch {
    $script:FatalError = $_.Exception.Message
    Write-Host ('[ERROR CONTROLADO] ' + $script:FatalError) -ForegroundColor Red
} finally {
    $script:Timer.Stop()
    Save-JWADReport

    Write-Host ''
    Write-Host '================ REPORTE FINAL ================' -ForegroundColor Green
    Write-Host ('Equipo: ' + $script:Hardware.fabricante + ' ' + $script:Hardware.modelo)
    Write-Host ('CPU: ' + $script:Hardware.procesador)
    Write-Host ('RAM: ' + $script:Hardware.memoria_ram_total_gb + ' GB | Uso: ' + $script:Hardware.uso_actual_ram_porcentaje + '%')
    Write-Host ('Disco C:: ' + $script:Hardware.almacenamiento_total_gb + ' GB | Uso: ' + $script:Hardware.uso_actual_almacenamiento_porcentaje + '%')
    if ($null -ne $script:Hardware.temperatura_termica_wmi_c) {
        Write-Host ('Zona térmica ACPI WMI: ' + $script:Hardware.temperatura_termica_wmi_c + ' °C') -ForegroundColor Yellow
    } else {
        Write-Host 'Zona térmica ACPI WMI: no disponible (no equivale necesariamente a sensor CPU).' -ForegroundColor DarkGray
    }
    Write-Host ('Duración: ' + [Math]::Round($script:Timer.Elapsed.TotalSeconds, 2) + ' segundos')
    Write-Host ('Reporte: ' + $script:ReportPath) -ForegroundColor Green

    [System.Threading.Monitor]::Enter($script:Results.SyncRoot)
    try { $finalResults = @($script:Results.ToArray()) }
    finally { [System.Threading.Monitor]::Exit($script:Results.SyncRoot) }
    foreach ($item in $finalResults) {
        $color = if ($item.estado -eq 'FAILED') { 'Red' } elseif ($item.estado -eq 'DESACTUALIZADO') { 'Yellow' } else { 'Green' }
        Write-Host ('  [' + $item.estado + '] ' + $item.app_name + ' | origen=' + $item.fuente + ' | ' + $item.tiempo_instalacion_segundos + ' s') -ForegroundColor $color
        if ($item.error_mensaje) { Write-Host ('       ' + $item.error_mensaje) -ForegroundColor DarkGray }
    }
    Write-Host '================================================' -ForegroundColor Green

    if (Test-Path -LiteralPath $script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $ErrorActionPreference = $script:OriginalErrorActionPreference
    $ProgressPreference = $script:OriginalProgressPreference
}
