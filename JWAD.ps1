#requires -Version 5.1
<#
JWAD - Windows App Deployer
Version: 3.0 (arquitectura de fallback Winget -> Scoop -> Direct)
Compatibilidad objetivo: Windows 10/11 x64; Windows PowerShell 5.1 y PowerShell 7+

IMPORTANTE:
- Ejecutar preferentemente como archivo local, después de revisar su contenido.
- No se cambian políticas de ejecución de forma persistente.
- Scoop se instala por usuario. Si el proceso está elevado, el bootstrap de Scoop
  requiere autorización explícita mediante JWAD_ALLOW_SCOOP_ADMIN=1.
- El fallback directo solo funciona cuando la aplicación tiene una fuente, un
  patrón de asset y argumentos silenciosos verificados/configurados.
- Nunca se selecciona un EXE/MSI arbitrario por ser el primer archivo del release.
#>

[CmdletBinding()]
param(
    [switch]$SkipTelemetry,
    [ValidateRange(0, 10)][int]$GitHubMaxRetries = 3
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# CONFIGURACION GLOBAL
# -----------------------------------------------------------------------------
$script:JWADVersion = '3.0'
$script:JWADStarted = [System.Diagnostics.Stopwatch]::StartNew()
$script:JWADIsAdmin = $false
$script:ScoopBootstrapAttempted = $false
$script:ScoopBootstrapSucceeded = $false
$script:ScoopCommand = $null
$script:InstallResults = New-Object 'System.Collections.Generic.List[object]'
$script:LogDirectory = Join-Path $env:LOCALAPPDATA 'JWAD\Logs'
$script:TempDirectory = Join-Path $env:TEMP 'JWAD'

$desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) {
    $desktop = $env:USERPROFILE
}
$script:ReportPath = Join-Path $desktop 'Reporte_Despliegue_JWAD.json'
$script:LogPath = Join-Path $script:LogDirectory ('JWAD_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

foreach ($directory in @($script:LogDirectory, $script:TempDirectory)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

# Windows PowerShell 5.1 en .NET Framework antiguo puede requerir TLS 1.2 explícito.
# PowerShell 7 conserva el protocolo seguro predeterminado del sistema.
if ($PSVersionTable.PSVersion.Major -eq 5) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # La conectividad HTTPS podrá fallar posteriormente y será capturada por el fallback.
    }
}

# -----------------------------------------------------------------------------
# PRESENTACION Y LOG
# -----------------------------------------------------------------------------
function Write-JWADMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'TITLE')][string]$Level = 'INFO'
    )

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'TITLE' { 'Cyan' }
        default { 'Gray' }
    }
    $line = '[{0}] {1}' -f $Level, $Message
    Write-Host $line -ForegroundColor $color
    try {
        Add-Content -LiteralPath $script:LogPath -Value ('{0} {1}' -f (Get-Date -Format 'o'), $line) -Encoding UTF8
    }
    catch {
        # Un fallo del log no debe detener las instalaciones.
    }
}

function Show-JWADProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(0, 1000)][int]$Current,
        [Parameter(Mandatory = $true)][ValidateRange(1, 1000)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $barWidth = 28
    $ratio = [Math]::Min(1.0, [double]$Current / [double]$Total)
    $filled = [int][Math]::Round($barWidth * $ratio)
    $empty = $barWidth - $filled
    $elapsed = [Math]::Round($script:JWADStarted.Elapsed.TotalSeconds, 1)
    Write-Host ''
    Write-Host ('  [{0,2}/{1,2}] {2}' -f $Current, $Total, $Label) -ForegroundColor Cyan
    Write-Host '  [' -NoNewline -ForegroundColor Blue
    if ($filled -gt 0) { Write-Host ('#' * $filled) -NoNewline -ForegroundColor Green }
    if ($empty -gt 0) { Write-Host ('.' * $empty) -NoNewline -ForegroundColor DarkBlue }
    Write-Host ('] {0}s' -f $elapsed) -ForegroundColor White
}

function Test-JWADAdministrator {
    [CmdletBinding()]
    param()
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function ConvertTo-JWADQuotedArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    # Start-Process acepta una cadena de argumentos. Se escapan comillas dobles
    # para evitar romper el límite entre argumentos.
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-JWADProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ArgumentList,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 1800
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $FilePath
    $processInfo.Arguments = $ArgumentList
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    try {
        if (-not $process.Start()) { throw ('No se pudo iniciar el proceso: {0}' -f $FilePath) }
        # Leer stdout/stderr de forma asíncrona evita bloquear el proceso si llena los buffers.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [int][Math]::Min([int]::MaxValue, ($TimeoutSeconds * 1000))
        if (-not $process.WaitForExit($timeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            throw ('Tiempo máximo agotado ({0}s): {1}' -f $TimeoutSeconds, $FilePath)
        }
        $process.WaitForExit()
        return [PSCustomObject]@{
            ExitCode = [int]$process.ExitCode
            Output   = [string]$stdoutTask.Result
            Error    = [string]$stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function New-JWADAttempt {
    [CmdletBinding()]
    param(
        [string]$Method,
        [string]$Outcome,
        [string]$Message,
        [Nullable[int]]$ExitCode = $null
    )
    return [PSCustomObject]@{
        metodo       = $Method
        resultado    = $Outcome
        codigo_salida = $ExitCode
        detalle      = $Message
        timestamp    = (Get-Date -Format 'o')
    }
}

function New-JWADResult {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Status,
        [string]$Method,
        [string]$Version = 'N/A',
        [double]$Seconds = 0,
        [object[]]$Attempts = @(),
        [string]$ErrorMessage = $null
    )
    return [PSCustomObject]@{
        app_name                    = $Name
        estado                      = $Status
        metodo_instalacion          = $Method
        version_instalada           = $Version
        tiempo_instalacion_segundos = [Math]::Round($Seconds, 2)
        intentos                    = @($Attempts)
        error_mensaje               = $ErrorMessage
    }
}

# -----------------------------------------------------------------------------
# NIVEL 1: WINGET
# -----------------------------------------------------------------------------
function Invoke-JWADWingetInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WingetId,
        [string]$CustomArguments = ''
    )

    $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue
    }
    if (-not $command) {
        throw 'Winget no está instalado o no está disponible en PATH.'
    }

    $wingetArguments = @(
        'install', '--id', (ConvertTo-JWADQuotedArgument $WingetId),
        '--exact', '--silent', '--accept-package-agreements',
        '--accept-source-agreements', '--architecture', 'x64'
    )
    if (-not [string]::IsNullOrWhiteSpace($CustomArguments)) {
        $wingetArguments += @('--custom', (ConvertTo-JWADQuotedArgument $CustomArguments))
    }

    $processResult = Invoke-JWADProcess -FilePath $command.Source -ArgumentList ($wingetArguments -join ' ')
    if ($processResult.ExitCode -eq 0) {
        return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED'; ExitCode = 0; Detail = 'Winget terminó correctamente.' }
    }
    if ($processResult.ExitCode -in @(3010, -1978334965)) {
        return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED_REBOOT_REQUIRED'; ExitCode = $processResult.ExitCode; Detail = 'WinGet terminó correctamente; se requiere reinicio o el reinicio fue iniciado.' }
    }
    # Códigos oficiales WinGet: INSTALL_ALREADY_INSTALLED,
    # PACKAGE_ALREADY_INSTALLED y INSTALL_DOWNGRADE (ya hay versión superior).
    # No se activa Scoop/Direct para evitar instalar una segunda copia.
    if ($processResult.ExitCode -in @(-1978334963, -1978335135, -1978334962)) {
        return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED_ALREADY_PRESENT'; ExitCode = $processResult.ExitCode; Detail = 'WinGet informa que ya hay una versión instalada o una versión superior.' }
    }

    $combinedOutput = ('{0}{1}{2}' -f [string]$processResult.Output, [Environment]::NewLine, [string]$processResult.Error).Trim()
    if ($combinedOutput.Length -gt 2000) { $combinedOutput = $combinedOutput.Substring(0, 2000) }
    $detail = ('Winget ExitCode={0}. {1}' -f $processResult.ExitCode, $combinedOutput).Trim()
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = 'Winget devolvió un código de salida distinto de cero.'
    }
    throw $detail
}

# -----------------------------------------------------------------------------
# NIVEL 2: SCOOP (BOOTSTRAP BAJO DEMANDA)
# -----------------------------------------------------------------------------
function Get-JWADScoopCommand {
    [CmdletBinding()]
    param()
    $cmd = Get-Command -Name 'scoop' -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd }
    return $null
}

function Invoke-JWADScoopCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $cmd = Get-JWADScoopCommand
    if (-not $cmd) { throw 'El comando scoop no está disponible.' }

    $source = $cmd.Path
    if ([string]::IsNullOrWhiteSpace($source)) { $source = $cmd.Source }
    if ([string]::IsNullOrWhiteSpace($source)) { $source = $cmd.Definition }
    if ([string]::IsNullOrWhiteSpace($source)) { throw 'No se pudo resolver la ruta del ejecutable/script Scoop.' }

    # Evita reutilizar el LASTEXITCODE de un proceso externo anterior.
    $global:LASTEXITCODE = 0
    $output = @(& $source @Arguments 2>&1 | Out-String)
    $code = 0
    if ($LASTEXITCODE -is [int]) { $code = [int]$LASTEXITCODE }
    if ($code -ne 0) {
        $text = ($output -join '').Trim()
        throw ('Scoop ExitCode={0}. {1}' -f $code, $text)
    }
    return ($output -join '').Trim()
}

function Install-JWADScoopBootstrap {
    [CmdletBinding()]
    param()

    if ($script:ScoopBootstrapAttempted) {
        if ($script:ScoopBootstrapSucceeded) { return }
        throw 'El bootstrap de Scoop ya se intentó y falló en esta ejecución.'
    }
    $script:ScoopBootstrapAttempted = $true

    if ($null -ne (Get-JWADScoopCommand)) {
        $script:ScoopCommand = Get-JWADScoopCommand
        $script:ScoopBootstrapSucceeded = $true
        return
    }

    $policy = Get-ExecutionPolicy
    if ($policy.ToString() -in @('Restricted', 'AllSigned')) {
        throw ('ExecutionPolicy efectiva={0}; no se intentará eludirla. Configure una política autorizada o use el fallback directo.' -f $policy)
    }

    if ($script:JWADIsAdmin -and $env:JWAD_ALLOW_SCOOP_ADMIN -ne '1') {
        throw 'La consola está elevada. Scoop no se instalará como administrador sin autorización explícita. Defina JWAD_ALLOW_SCOOP_ADMIN=1 si acepta ese modo.'
    }

    $installerUrl = $env:JWAD_SCOOP_INSTALLER_URL
    if ([string]::IsNullOrWhiteSpace($installerUrl)) { $installerUrl = 'https://get.scoop.sh' }
    if (-not $installerUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'JWAD_SCOOP_INSTALLER_URL debe utilizar HTTPS.'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:JWAD_SCOOP_REPO_URL)) {
        $env:SCOOP_REPO = $env:JWAD_SCOOP_REPO_URL
    }

    $requestParams = @{ Uri = $installerUrl; TimeoutSec = 60; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -eq 5) { $requestParams.UseBasicParsing = $true }
    $installerResponse = Invoke-WebRequest @requestParams
    $installerText = [string]$installerResponse.Content
    if ([string]::IsNullOrWhiteSpace($installerText) -or $installerText.Length -lt 1000) {
        throw 'La respuesta del instalador de Scoop está vacía o no parece un script válido.'
    }

    # El patrón & { script } refleja el procedimiento oficial de Scoop y permite
    # pasar -RunAsAdmin solo cuando se autorizó expresamente.
    $invocation = "& {`n$installerText`n}"
    if ($script:JWADIsAdmin) { $invocation += ' -RunAsAdmin' }
    Invoke-Expression $invocation | Out-Null

    $script:ScoopCommand = Get-JWADScoopCommand
    if (-not $script:ScoopCommand) {
        throw 'El instalador de Scoop terminó, pero el comando scoop no quedó disponible.'
    }
    $script:ScoopBootstrapSucceeded = $true
}

function Invoke-JWADScoopInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScoopName,
        [ValidateSet('main', 'extras')][string]$Bucket = 'main'
    )

    Install-JWADScoopBootstrap

    $bucketList = Invoke-JWADScoopCommand -Arguments @('bucket', 'list')
    $bucketExists = [regex]::IsMatch($bucketList, ('(?im)^\s*{0}\s+' -f [regex]::Escape($Bucket)))
    if (-not $bucketExists) {
        $bucketArgs = @('bucket', 'add', $Bucket)
        $bucketUrl = ''
        if ($Bucket -eq 'extras') { $bucketUrl = $env:JWAD_SCOOP_EXTRAS_URL }
        if ($Bucket -eq 'main') { $bucketUrl = $env:JWAD_SCOOP_MAIN_URL }
        if (-not [string]::IsNullOrWhiteSpace($bucketUrl)) {
            if (-not $bucketUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
                throw ('JWAD_SCOOP_{0}_URL debe utilizar HTTPS.' -f $Bucket.ToUpperInvariant())
            }
            $bucketArgs += $bucketUrl
        }
        [void](Invoke-JWADScoopCommand -Arguments $bucketArgs)
    }

    $package = if ($Bucket -eq 'main') { $ScoopName } else { 'extras/{0}' -f $ScoopName }
    [void](Invoke-JWADScoopCommand -Arguments @('install', $package))
    return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED'; ExitCode = 0; Detail = ('Scoop instaló {0}.' -f $package) }
}

# -----------------------------------------------------------------------------
# NIVEL 3: DESCARGA DIRECTA Y VERIFICACION
# -----------------------------------------------------------------------------
function Get-JWADHttpStatusCode {
    [CmdletBinding()]
    param([System.Exception]$Exception)
    try {
        if ($Exception.Response -and $Exception.Response.StatusCode) {
            return [int]$Exception.Response.StatusCode
        }
    }
    catch { }
    return 0
}

function Get-JWADResponseHeader {
    [CmdletBinding()]
    param(
        [System.Exception]$Exception,
        [string]$Name
    )
    try {
        if ($Exception.Response -and $Exception.Response.Headers) {
            return [string]$Exception.Response.Headers[$Name]
        }
    }
    catch { }
    return ''
}

function Get-JWADGitHubRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [int]$MaxRetries = 3
    )

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'GitHubRepo debe tener formato propietario/repositorio.'
    }

    $apiBase = $env:JWAD_GITHUB_API_BASE
    if ([string]::IsNullOrWhiteSpace($apiBase)) { $apiBase = 'https://api.github.com' }
    $apiBase = $apiBase.TrimEnd('/')
    if (-not $apiBase.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'JWAD_GITHUB_API_BASE debe utilizar HTTPS.'
    }

    $uri = '{0}/repos/{1}/releases/latest' -f $apiBase, $Repository
    $headers = @{
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2026-03-10'
        'User-Agent' = 'JWAD-Windows-App-Deployer/3.0'
    }
    $token = $env:JWAD_GITHUB_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) { $token = $env:GH_TOKEN }
    if ([string]::IsNullOrWhiteSpace($token)) { $token = $env:GITHUB_TOKEN }
    if (-not [string]::IsNullOrWhiteSpace($token)) { $headers.Authorization = 'Bearer ' + $token }

    $attempt = 0
    while ($attempt -le $MaxRetries) {
        try {
            $requestParams = @{ Uri = $uri; Headers = $headers; TimeoutSec = 45; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -eq 5) { $requestParams.UseBasicParsing = $true }
            $response = Invoke-WebRequest @requestParams
            return ($response.Content | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            $status = Get-JWADHttpStatusCode -Exception $_.Exception
            $remaining = Get-JWADResponseHeader -Exception $_.Exception -Name 'X-RateLimit-Remaining'
            $retryAfter = Get-JWADResponseHeader -Exception $_.Exception -Name 'Retry-After'
            $reset = Get-JWADResponseHeader -Exception $_.Exception -Name 'X-RateLimit-Reset'
            $errorDetail = [string]$_.ErrorDetails.Message
            $combinedError = ('{0} {1}' -f $_.Exception.Message, $errorDetail)
            $isRateLimit = ($status -eq 429) -or ($status -eq 403 -and ($remaining -eq '0' -or $combinedError -match '(?i)rate limit|secondary rate limit|abuse detection'))

            if (-not $isRateLimit -or $attempt -ge $MaxRetries) { throw }

            $delay = 0
            $parsedDelay = 0
            if ([int]::TryParse($retryAfter, [ref]$parsedDelay)) {
                $delay = $parsedDelay
            }
            elseif (-not [string]::IsNullOrWhiteSpace($retryAfter)) {
                $retryDate = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($retryAfter, [ref]$retryDate)) {
                    $delay = [int][Math]::Max(1, [Math]::Ceiling(($retryDate - [DateTimeOffset]::UtcNow).TotalSeconds))
                }
            }
            if ($delay -eq 0 -and $remaining -eq '0' -and $reset -match '^\d+$') {
                $resetTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$reset)
                $delay = [int][Math]::Max(1, [Math]::Ceiling(($resetTime - [DateTimeOffset]::UtcNow).TotalSeconds))
            }
            elseif ($delay -eq 0) {
                # GitHub recomienda al menos 60 s ante rate limit secundario sin Retry-After.
                $delay = 60 * ($attempt + 1)
            }

            $maxWait = 120
            if ($env:JWAD_GITHUB_MAX_WAIT_SECONDS -match '^\d+$') {
                $maxWait = [Math]::Max(0, [int]$env:JWAD_GITHUB_MAX_WAIT_SECONDS)
            }
            if ($delay -gt $maxWait) {
                throw ('GitHub rate limit. La espera indicada ({0}s) supera el máximo configurado ({1}s).' -f $delay, $maxWait)
            }
            Start-Sleep -Seconds ([Math]::Max(1, $delay))
            $attempt++
        }
    }
    throw 'No fue posible consultar la versión más reciente en GitHub.'
}

function Get-JWADDirectDownloadUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$OriginalUrl)

    $mirror = $env:JWAD_GITHUB_DOWNLOAD_BASE
    if ($OriginalUrl -notmatch '^https://github\.com/') { return $OriginalUrl }
    if (-not [string]::IsNullOrWhiteSpace($mirror)) {
        if (-not $mirror.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'JWAD_GITHUB_DOWNLOAD_BASE debe utilizar HTTPS.'
        }
        $relative = $OriginalUrl -replace '^https://github\.com/', ''
        return ($mirror.TrimEnd('/') + '/' + $relative)
    }
    return $OriginalUrl
}

function Invoke-JWADDirectInstall {
    [CmdletBinding()]
    param(
        [string]$AppName,
        [string]$Repository,
        [string]$AssetRegex,
        [string]$Arguments = '',
        [string]$ExpectedSHA256 = '',
        [string]$DirectUrl = '',
        [string]$DirectFileName = '',
        [string]$ExpectedSigner = ''
    )

    $version = 'N/A'
    $downloadUrl = ''
    $assetName = ''
    $expectedHash = $ExpectedSHA256

    if (-not [string]::IsNullOrWhiteSpace($Repository)) {
        if ([string]::IsNullOrWhiteSpace($AssetRegex)) {
            throw 'GitHubRepo está configurado, pero RegexAsset no. No se seleccionará un asset genérico.'
        }
        $release = Get-JWADGitHubRelease -Repository $Repository -MaxRetries $GitHubMaxRetries
        $version = [string]$release.tag_name
        $matches = @($release.assets | Where-Object { $_.name -match $AssetRegex })
        if ($matches.Count -ne 1) {
            throw ('RegexAsset produjo {0} coincidencias; se requiere exactamente una.' -f $matches.Count)
        }
        $asset = $matches[0]
        $assetName = [string]$asset.name
        $downloadUrl = [string]$asset.browser_download_url
        if ([string]::IsNullOrWhiteSpace($expectedHash) -and [string]$asset.digest -match '^sha256:([A-Fa-f0-9]{64})$') {
            $expectedHash = $Matches[1]
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($DirectUrl)) {
        $downloadUrl = $DirectUrl
        $assetName = $DirectFileName
        if ([string]::IsNullOrWhiteSpace($assetName)) {
            $assetName = [IO.Path]::GetFileName(([Uri]$DirectUrl).AbsolutePath)
        }
    }
    else {
        throw 'No existe GitHubRepo ni DirectUrl configurado para el fallback directo.'
    }

    if (-not $downloadUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'La URL de descarga no utiliza HTTPS.'
    }

    $downloadUrl = Get-JWADDirectDownloadUrl -OriginalUrl $downloadUrl
    $extension = [IO.Path]::GetExtension($assetName).ToLowerInvariant()
    if ($extension -notin @('.exe', '.msi')) {
        throw ('Tipo de asset no admitido para instalación directa: {0}. Solo EXE/MSI explícitos.' -f $extension)
    }

    $downloadPath = Join-Path $script:TempDirectory ([Guid]::NewGuid().ToString('N') + $extension)
    try {
        $downloadParams = @{ Uri = $downloadUrl; OutFile = $downloadPath; TimeoutSec = 180; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -eq 5) { $downloadParams.UseBasicParsing = $true }
        Invoke-WebRequest @downloadParams

        if (-not (Test-Path -LiteralPath $downloadPath) -or (Get-Item -LiteralPath $downloadPath).Length -le 0) {
            throw 'La descarga no produjo un archivo válido.'
        }

        if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
            if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'ExpectedSHA256 no tiene formato SHA-256 válido.' }
            $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
                throw 'El SHA-256 descargado no coincide con el digest/hash esperado.'
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ExpectedSigner)) {
            $signature = Get-AuthenticodeSignature -FilePath $downloadPath
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike ('*{0}*' -f $ExpectedSigner)) {
                throw 'La firma Authenticode no es válida o el firmante no coincide con ExpectedSigner.'
            }
        }
        else {
            throw 'SIN INFORMACIÓN: el asset no publica digest SHA-256 y no hay ExpectedSHA256/ExpectedSigner configurado. Descarga rechazada.'
        }

        if ($extension -eq '.msi') {
            $msiArgs = '/i {0} /qn /norestart' -f (ConvertTo-JWADQuotedArgument $downloadPath)
            $proc = Invoke-JWADProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $msiArgs
        }
        else {
            if ([string]::IsNullOrWhiteSpace($Arguments)) {
                throw 'SIN INFORMACIÓN: no se han configurado argumentos silenciosos verificados para este EXE.'
            }
            $proc = Invoke-JWADProcess -FilePath $downloadPath -ArgumentList $Arguments
        }

        if ($proc.ExitCode -eq 0) {
            return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED'; ExitCode = 0; Version = $version; Detail = ('Instalación directa verificada: {0}' -f $assetName) }
        }
        if ($proc.ExitCode -in @(3010, 1641)) {
            return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED_REBOOT_REQUIRED'; ExitCode = $proc.ExitCode; Version = $version; Detail = ('Instalación directa verificada; requiere reinicio: {0}' -f $assetName) }
        }
        $installerOutput = ('{0}{1}{2}' -f [string]$proc.Output, [Environment]::NewLine, [string]$proc.Error).Trim()
        if ($installerOutput.Length -gt 2000) { $installerOutput = $installerOutput.Substring(0, 2000) }
        throw ('El instalador directo terminó con ExitCode={0}. {1}' -f $proc.ExitCode, $installerOutput)
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# -----------------------------------------------------------------------------
# WRAPPER UNIVERSAL: WINGET -> SCOOP -> DIRECT
# -----------------------------------------------------------------------------
function Install-UniversalApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [string]$WingetId = '',
        [string]$WingetCustomArgs = '',
        [string]$ScoopName = '',
        [ValidateSet('main', 'extras')][string]$ScoopBucket = 'main',
        [string]$GitHubRepo = '',
        [string]$RegexAsset = '',
        [string]$DirectArguments = '',
        [string]$ExpectedSHA256 = '',
        [string]$DirectUrl = '',
        [string]$DirectFileName = '',
        [string]$ExpectedSigner = ''
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $attempts = New-Object 'System.Collections.Generic.List[object]'
    $finalStatus = 'FAILED'
    $finalMethod = 'NONE'
    $finalVersion = 'N/A'
    $finalError = $null

    # Nivel 1: Winget
    if (-not [string]::IsNullOrWhiteSpace($WingetId)) {
        try {
            $r = Invoke-JWADWingetInstall -WingetId $WingetId -CustomArguments $WingetCustomArgs
            $attempts.Add((New-JWADAttempt -Method 'Winget' -Outcome 'SUCCESS' -Message $r.Detail -ExitCode $r.ExitCode))
            $finalStatus = $r.Status
            $finalMethod = 'Winget'
            $finalError = $null
        }
        catch {
            $message = $_.Exception.Message
            $attempts.Add((New-JWADAttempt -Method 'Winget' -Outcome 'FAILED' -Message $message))
            $finalError = $message
        }
    }
    else {
        $attempts.Add((New-JWADAttempt -Method 'Winget' -Outcome 'NOT_CONFIGURED' -Message 'SIN INFORMACIÓN: WingetId no está configurado.'))
    }

    # Nivel 2: Scoop solo si hay un manifiesto identificado.
    if ($finalMethod -eq 'NONE') {
        if (-not [string]::IsNullOrWhiteSpace($ScoopName)) {
            try {
                $r = Invoke-JWADScoopInstall -ScoopName $ScoopName -Bucket $ScoopBucket
                $attempts.Add((New-JWADAttempt -Method 'Scoop' -Outcome 'SUCCESS' -Message $r.Detail -ExitCode $r.ExitCode))
                $finalStatus = $r.Status
                $finalMethod = 'Scoop'
                $finalError = $null
            }
            catch {
                $message = $_.Exception.Message
                $attempts.Add((New-JWADAttempt -Method 'Scoop' -Outcome 'FAILED' -Message $message))
                $finalError = $message
            }
        }
        else {
            $attempts.Add((New-JWADAttempt -Method 'Scoop' -Outcome 'NOT_CONFIGURED' -Message 'SIN INFORMACIÓN: no se ha verificado un manifiesto Scoop para esta aplicación.'))
        }
    }

    # Nivel 3: fuente directa, si se ha definido una ruta de confianza.
    if ($finalMethod -eq 'NONE') {
        if (-not [string]::IsNullOrWhiteSpace($GitHubRepo) -or -not [string]::IsNullOrWhiteSpace($DirectUrl)) {
            try {
                $r = Invoke-JWADDirectInstall -AppName $AppName -Repository $GitHubRepo -AssetRegex $RegexAsset -Arguments $DirectArguments -ExpectedSHA256 $ExpectedSHA256 -DirectUrl $DirectUrl -DirectFileName $DirectFileName -ExpectedSigner $ExpectedSigner
                $attempts.Add((New-JWADAttempt -Method 'Direct' -Outcome 'SUCCESS' -Message $r.Detail -ExitCode $r.ExitCode))
                $finalStatus = $r.Status
                $finalMethod = 'Direct'
                $finalVersion = $r.Version
                $finalError = $null
            }
            catch {
                $message = $_.Exception.Message
                $attempts.Add((New-JWADAttempt -Method 'Direct' -Outcome 'FAILED' -Message $message))
                $finalError = $message
            }
        }
        else {
            $attempts.Add((New-JWADAttempt -Method 'Direct' -Outcome 'NOT_CONFIGURED' -Message 'SIN INFORMACIÓN: no existe una URL/release directa validada para esta aplicación.'))
        }
    }

    $timer.Stop()
    if ($finalMethod -eq 'NONE') {
        $finalStatus = 'FAILED'
        $finalMethod = 'NONE'
    }
    $result = New-JWADResult -Name $AppName -Status $finalStatus -Method $finalMethod -Version $finalVersion -Seconds $timer.Elapsed.TotalSeconds -Attempts $attempts.ToArray() -ErrorMessage $finalError
    $script:InstallResults.Add($result)

    $statusLabel = if ($finalStatus -like 'INSTALLED*') { 'OK' } else { 'FAILED' }
    Write-JWADMessage -Level $statusLabel -Message ('{0}: {1} mediante {2}' -f $AppName, $finalStatus, $finalMethod)
    return $result
}

# -----------------------------------------------------------------------------
# VALIDACION DE .NET FRAMEWORK 4.x (NO SE FUERZA REINSTALACION)
# -----------------------------------------------------------------------------
function Test-JWADDotNetFramework {
    [CmdletBinding()]
    param()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        $release = [int]$key.Release
        $timer.Stop()
        if ($release -ge 528040) {
            return (New-JWADResult -Name '.NET Framework 4.8+' -Status 'VALIDATED' -Method 'Registry' -Version ('Release {0}' -f $release) -Seconds $timer.Elapsed.TotalSeconds)
        }
        return (New-JWADResult -Name '.NET Framework 4.8+' -Status 'OUTDATED' -Method 'Registry' -Version ('Release {0}' -f $release) -Seconds $timer.Elapsed.TotalSeconds -ErrorMessage 'Actualizar mediante Windows Update o el instalador oficial correspondiente.')
    }
    catch {
        $timer.Stop()
        return (New-JWADResult -Name '.NET Framework 4.8+' -Status 'UNKNOWN' -Method 'Registry' -Version 'N/A' -Seconds $timer.Elapsed.TotalSeconds -ErrorMessage $_.Exception.Message)
    }
}

# -----------------------------------------------------------------------------
# TELEMETRIA ROBUSTA: SI FALLA, NO INVALIDA LOS RESULTADOS DE INSTALACION
# -----------------------------------------------------------------------------
function Get-JWADTelemetry {
    [CmdletBinding()]
    param()

    $specs = [ordered]@{
        fabricante = $null
        modelo = $null
        procesador = $null
        arquitectura = $env:PROCESSOR_ARCHITECTURE
        memoria_ram_total_gb = $null
        uso_actual_ram_porcentaje = $null
        almacenamiento_total_gb = $null
        uso_actual_almacenamiento_porcentaje = $null
        sistema_operativo = $null
        version_sistema = $null
    }
    $temperatureReadings = New-Object 'System.Collections.Generic.List[object]'
    $finalTemp = $null
    $telemetryErrors = New-Object 'System.Collections.Generic.List[string]'

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $specs.fabricante = $computer.Manufacturer
        $specs.modelo = $computer.Model
        $ramBytes = [double]$computer.TotalPhysicalMemory
        if ($ramBytes -gt 0) { $specs.memoria_ram_total_gb = [Math]::Round($ramBytes / 1GB, 2) }
    }
    catch { $telemetryErrors.Add(('Win32_ComputerSystem: {0}' -f $_.Exception.Message)) }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $specs.sistema_operativo = $os.Caption
        $specs.version_sistema = $os.Version
        $totalKB = [double]$os.TotalVisibleMemorySize
        $freeKB = [double]$os.FreePhysicalMemory
        if ($totalKB -gt 0) { $specs.uso_actual_ram_porcentaje = [Math]::Round((($totalKB - $freeKB) / $totalKB) * 100, 2) }
    }
    catch { $telemetryErrors.Add(('Win32_OperatingSystem: {0}' -f $_.Exception.Message)) }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu) { $specs.procesador = $cpu.Name }
    }
    catch { $telemetryErrors.Add(('Win32_Processor: {0}' -f $_.Exception.Message)) }

    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop | Select-Object -First 1
        if ($disk -and [double]$disk.Size -gt 0) {
            $specs.almacenamiento_total_gb = [Math]::Round(([double]$disk.Size / 1GB), 2)
            $specs.uso_actual_almacenamiento_porcentaje = [Math]::Round(((1 - ([double]$disk.FreeSpace / [double]$disk.Size)) * 100), 2)
        }
    }
    catch { $telemetryErrors.Add(('Win32_LogicalDisk: {0}' -f $_.Exception.Message)) }

    try {
        $zone = Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop | Select-Object -First 1
        if ($zone -and $null -ne $zone.CurrentTemperature) {
            # CurrentTemperature: décimas de Kelvin; 2732 equivale a 273.2 K.
            $finalTemp = [Math]::Round((([double]$zone.CurrentTemperature - 2732) / 10), 2)
            $temperatureReadings.Add([PSCustomObject]@{ metodo = 'MSAcpi_ThermalZoneTemperature'; valor_celsius = $finalTemp; estado = 'SUCCESS' })
        }
        else {
            $temperatureReadings.Add([PSCustomObject]@{ metodo = 'MSAcpi_ThermalZoneTemperature'; valor_celsius = $null; estado = 'UNSUPPORTED' })
        }
    }
    catch {
        $temperatureReadings.Add([PSCustomObject]@{ metodo = 'MSAcpi_ThermalZoneTemperature'; valor_celsius = $null; estado = 'UNAVAILABLE' })
    }

    return [PSCustomObject]@{
        specs_computador = $specs
        diagnosticos_temperatura = [ordered]@{
            lecturas = $temperatureReadings.ToArray()
            temperatura_final_corroborada = $finalTemp
        }
        errores_telemetria = $telemetryErrors.ToArray()
    }
}

# -----------------------------------------------------------------------------
# PRECONDICIONES Y CATALOGO
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host (' WINDOWS APP DEPLOYER - JWAD v{0}' -f $script:JWADVersion) -ForegroundColor Cyan
Write-Host ' Fallback: Winget -> Scoop -> Descarga directa verificada' -ForegroundColor DarkCyan
Write-Host '============================================================' -ForegroundColor Cyan

if (-not [Environment]::Is64BitOperatingSystem -or
    ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64')) {
    Write-JWADMessage -Level 'ERROR' -Message 'Este despliegue requiere un sistema operativo Windows x64 (AMD64).'
    return
}
$osVersion = [Environment]::OSVersion.Version
if ($osVersion.Major -lt 10 -or $osVersion.Build -lt 10240) {
    Write-JWADMessage -Level 'ERROR' -Message ('Se requiere Windows 10/11 (build 10240 o posterior). Detectado: {0}.' -f $osVersion)
    return
}
$clientWindowsValidated = $false
$osDescription = ''
try {
    $osIdentity = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $osDescription = [string]$osIdentity.Caption
    $clientWindowsValidated = ([int]$osIdentity.ProductType -eq 1 -and $osDescription -match 'Windows 10|Windows 11')
}
catch {
    # En algunas imágenes LTSC/WMI restringidas, se usa el registro como respaldo.
    try {
        $productType = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -Name ProductType -ErrorAction Stop).ProductType
        $productName = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName -ErrorAction Stop).ProductName
        $osDescription = $productName
        $clientWindowsValidated = ($productType -eq 'WinNT' -and $productName -match 'Windows 10|Windows 11')
    }
    catch {
        Write-JWADMessage -Level 'ERROR' -Message ('No fue posible validar el tipo de Windows mediante CIM ni registro: {0}' -f $_.Exception.Message)
        return
    }
}
if (-not $clientWindowsValidated) {
    Write-JWADMessage -Level 'ERROR' -Message ('El sistema detectado no es un cliente Windows 10/11 admitido: {0}.' -f $osDescription)
    return
}
$script:JWADIsAdmin = Test-JWADAdministrator
if ($script:JWADIsAdmin) {
    Write-JWADMessage -Level 'INFO' -Message 'Contexto elevado detectado.'
}
else {
    Write-JWADMessage -Level 'WARN' -Message 'Contexto no elevado. Algunos instaladores podrán requerir permisos administrativos/UAC.'
}
Write-JWADMessage -Level 'INFO' -Message ('PowerShell {0}; SO {1}-bit.' -f $PSVersionTable.PSVersion, $(if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }))

# El catálogo mantiene datos por paquete. Los campos vacíos son deliberados:
# no se inventan IDs, manifiestos, assets ni argumentos silenciosos.
$apps = @(
    [PSCustomObject]@{
        Name = 'Visual C++ Redistributable x64'; WingetId = 'Microsoft.VCRedist.2015+.x64'; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '/install /quiet /norestart';
        ExpectedSHA256 = ''; DirectUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'; DirectFileName = 'vc_redist.x64.exe'; ExpectedSigner = 'Microsoft Corporation'
    },
    [PSCustomObject]@{
        Name = 'Java Runtime Environment - Temurin 21 JRE'; WingetId = 'EclipseAdoptium.Temurin.21.JRE'; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = '7-Zip'; WingetId = '7zip.7zip'; WingetCustomArgs = '';
        ScoopName = '7zip'; ScoopBucket = 'main'; GitHubRepo = 'ip7z/7zip'; RegexAsset = '(?i)^7z[0-9]+-x64\.msi$'; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'Bulk Crap Uninstaller'; WingetId = 'Klocman.BulkCrapUninstaller'; WingetCustomArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'SumatraPDF'; WingetId = 'SumatraPDF.SumatraPDF'; WingetCustomArgs = '';
        ScoopName = 'sumatrapdf'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'AB Download Manager'; WingetId = ''; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = 'amir1376/ab-download-manager'; RegexAsset = '(?i)^(?!.*(arm64|aarch64|arm)).*(x64|win64|amd64).*\.(exe)$'; DirectArguments = '/S';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'WinRAR x64'; WingetId = 'RARLab.WinRAR'; WingetCustomArgs = '/S';
        ScoopName = 'winrar'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'VLC Media Player'; WingetId = 'VideoLAN.VLC'; WingetCustomArgs = '/S';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'Google Chrome'; WingetId = 'Google.Chrome'; WingetCustomArgs = '/silent /install';
        ScoopName = 'googlechrome'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'Mozilla Firefox'; WingetId = 'Mozilla.Firefox'; WingetCustomArgs = '-ms';
        ScoopName = 'firefox'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '/S';
        ExpectedSHA256 = ''; DirectUrl = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US'; DirectFileName = 'firefox-installer.exe'; ExpectedSigner = 'Mozilla Corporation'
    },
    [PSCustomObject]@{
        Name = 'Mullvad Browser'; WingetId = 'MullvadVPN.MullvadBrowser'; WingetCustomArgs = '/S';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'Microsoft Edge'; WingetId = 'Microsoft.Edge'; WingetCustomArgs = '/silent';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    },
    [PSCustomObject]@{
        Name = 'FlyPhotos'; WingetId = ''; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = 'riyasy/FlyPhotos'; RegexAsset = '(?i)^(?!.*(arm64|aarch64|arm)).*(x64|win64|amd64).*\.msi$'; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = ''
    }
)

# Total = 13 pasos de aplicación (VC++, Java + 11 apps) y una validación .NET.
$totalSteps = $apps.Count + 1
$step = 0

Write-Host ''
Write-JWADMessage -Level 'TITLE' -Message 'INICIO DE INSTALACIONES'
foreach ($app in $apps) {
    $step++
    Show-JWADProgress -Current $step -Total $totalSteps -Label $app.Name
    [void](Install-UniversalApp -AppName $app.Name -WingetId $app.WingetId -WingetCustomArgs $app.WingetCustomArgs -ScoopName $app.ScoopName -ScoopBucket $app.ScoopBucket -GitHubRepo $app.GitHubRepo -RegexAsset $app.RegexAsset -DirectArguments $app.DirectArguments -ExpectedSHA256 $app.ExpectedSHA256 -DirectUrl $app.DirectUrl -DirectFileName $app.DirectFileName -ExpectedSigner $app.ExpectedSigner)
}

$step++
Show-JWADProgress -Current $step -Total $totalSteps -Label '.NET Framework 4.8+ (validación)'
$dotNetResult = Test-JWADDotNetFramework
$script:InstallResults.Add($dotNetResult)
if ($dotNetResult.estado -eq 'VALIDATED') {
    Write-JWADMessage -Level 'OK' -Message ('.NET Framework validado: {0}' -f $dotNetResult.version_instalada)
}
else {
    Write-JWADMessage -Level 'WARN' -Message ('.NET Framework: {0}' -f $dotNetResult.estado)
}

# -----------------------------------------------------------------------------
# TELEMETRIA Y EXPORTACION JSON
# -----------------------------------------------------------------------------
$telemetry = $null
if (-not $SkipTelemetry) {
    Write-JWADMessage -Level 'INFO' -Message 'Recopilando telemetría del equipo...'
    try { $telemetry = Get-JWADTelemetry }
    catch { $telemetry = [PSCustomObject]@{ specs_computador = @{}; diagnosticos_temperatura = @{}; errores_telemetria = @($_.Exception.Message) } }
}
else {
    $telemetry = [PSCustomObject]@{ specs_computador = @{}; diagnosticos_temperatura = @{}; errores_telemetria = @('Omitida por -SkipTelemetry.') }
}

$script:JWADStarted.Stop()
$failed = @($script:InstallResults | Where-Object { $_.estado -eq 'FAILED' }).Count
$validationPending = @($script:InstallResults | Where-Object { $_.estado -in @('OUTDATED', 'UNKNOWN') }).Count
$report = [ordered]@{
    version_script = $script:JWADVersion
    timestamp = (Get-Date -Format 'o')
    equipo = $env:COMPUTERNAME
    usuario_ejecucion = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    contexto_administrador = $script:JWADIsAdmin
    powershell_version = [string]$PSVersionTable.PSVersion
    arquitectura_so = $env:PROCESSOR_ARCHITECTURE
    tiempo_total_ejecucion_segundos = [Math]::Round($script:JWADStarted.Elapsed.TotalSeconds, 2)
    resumen = [ordered]@{
        total_registros = $script:InstallResults.Count
        instalaciones_fallidas = $failed
        validaciones_pendientes = $validationPending
        instalaciones_exitosas = @($script:InstallResults | Where-Object { $_.estado -like 'INSTALLED*' -or $_.estado -eq 'VALIDATED' }).Count
    }
    specs_computador = $telemetry.specs_computador
    diagnosticos_temperatura = $telemetry.diagnosticos_temperatura
    errores_telemetria = $telemetry.errores_telemetria
    resultado_aplicaciones = $script:InstallResults.ToArray()
    configuracion_respaldo = [ordered]@{
        scoop_disponible_durante_ejecucion = $script:ScoopBootstrapSucceeded
        scoop_admin_autorizado = ($env:JWAD_ALLOW_SCOOP_ADMIN -eq '1')
        github_api_base_configurada = (-not [string]::IsNullOrWhiteSpace($env:JWAD_GITHUB_API_BASE))
        github_download_mirror_configurado = (-not [string]::IsNullOrWhiteSpace($env:JWAD_GITHUB_DOWNLOAD_BASE))
        scoop_main_mirror_configurado = (-not [string]::IsNullOrWhiteSpace($env:JWAD_SCOOP_MAIN_URL))
        scoop_extras_mirror_configurado = (-not [string]::IsNullOrWhiteSpace($env:JWAD_SCOOP_EXTRAS_URL))
        github_token_configurado = (-not [string]::IsNullOrWhiteSpace($env:JWAD_GITHUB_TOKEN) -or -not [string]::IsNullOrWhiteSpace($env:GH_TOKEN) -or -not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN))
    }
}

try {
    $json = $report | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $script:ReportPath -Value $json -Encoding UTF8
    Write-JWADMessage -Level 'OK' -Message ('Reporte JSON guardado: {0}' -f $script:ReportPath)
}
catch {
    Write-JWADMessage -Level 'ERROR' -Message ('No se pudo guardar el reporte JSON: {0}' -f $_.Exception.Message)
}

# -----------------------------------------------------------------------------
# RESUMEN FINAL
# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' RESUMEN FINAL JWAD' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
foreach ($item in $script:InstallResults) {
    $color = 'Green'
    if ($item.estado -eq 'FAILED') { $color = 'Red' }
    elseif ($item.estado -in @('OUTDATED', 'UNKNOWN')) { $color = 'Yellow' }
    Write-Host ('[{0}] {1} | método={2} | versión={3} | {4}s' -f $item.estado, $item.app_name, $item.metodo_instalacion, $item.version_instalada, $item.tiempo_instalacion_segundos) -ForegroundColor $color
}
Write-Host ''
Write-Host ('Fallos: {0} | Validaciones pendientes: {1} | Reporte: {2}' -f $failed, $validationPending, $script:ReportPath) -ForegroundColor Cyan
Write-Host ('Log: {0}' -f $script:LogPath) -ForegroundColor DarkGray
if ($failed -gt 0 -or $validationPending -gt 0) {
    Write-JWADMessage -Level 'WARN' -Message ('El proceso terminó con {0} fallos de instalación y {1} validaciones pendientes. Consulte el JSON/log.' -f $failed, $validationPending)
}
else {
    Write-JWADMessage -Level 'OK' -Message 'No se registraron fallos de instalación ni validaciones pendientes.'
}
