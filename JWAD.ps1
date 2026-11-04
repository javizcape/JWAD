#requires -Version 5.1
<#
.SYNOPSIS
    Despliegue secuencial y auditable de aplicaciones para Windows 10/11 x64.
.DESCRIPTION
    Compatible con Windows PowerShell 5.1 y PowerShell 7+ sobre Windows.
    Requiere ejecutar desde un archivo .ps1 para permitir una elevacion UAC
    supervisada del mismo archivo. No ejecuta codigo remoto mediante IEX.
.NOTES
    Los identificadores Winget y los repositorios GitHub se conservan del
    JWAD.ps1 suministrado. Deben validarse antes de cada despliegue productivo.
#>

[CmdletBinding()]
param(
    [string]$ExpectedUserSid
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# -----------------------------------------------------------------------------
# CONFIGURACION Y ESTADO PRIVADO DEL SCRIPT
# -----------------------------------------------------------------------------
$script:RunClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:FatalError = $null
$script:WingetPath = $null
$script:ReportSaved = $false
$script:ReportError = $null
$script:RunMutex = $null
$script:OwnsRunMutex = $false
$script:Telemetry = [ordered]@{
    fabricante = 'No disponible'
    modelo = 'No disponible'
    procesador = 'No disponible'
    memoria_ram_total_gb = $null
    uso_actual_ram_porcentaje = $null
    almacenamiento_total_gb = $null
    uso_actual_almacenamiento_porcentaje = $null
}
$script:ThermalZoneC = $null

$desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
if ([string]::IsNullOrWhiteSpace($desktopPath)) {
    $desktopPath = Join-Path $env:USERPROFILE 'Desktop'
}
$script:ReportPath = Join-Path $desktopPath 'Reporte_Despliegue.json'
$script:TempRoot = [System.IO.Path]::GetTempPath()

# -----------------------------------------------------------------------------
# FUNCIONES DE SOPORTE
# -----------------------------------------------------------------------------
function Write-JWADBanner {
    [CmdletBinding()]
    param()

    $lines = @(
        '     ___        ___    ____  ',
        '    | \ \      / / \  |  _ \ ',
        ' _  | |\ \ /\ / / _ \ | | | |',
        '| |_| | \ V  V / ___ \| |_| |',
        ' \___/   \_/\_/_/   \_\____/ '
    )

    Write-Host ''
    Write-Host '  ============================================' -ForegroundColor Cyan
    foreach ($line in $lines) {
        Write-Host "  $line" -ForegroundColor Cyan
    }
    Write-Host '         WINDOWS APP DEPLOYER - HARDENED' -ForegroundColor DarkCyan
    Write-Host '  ============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedRelaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [Parameter(Mandatory)]
        [string]$ExpectedUserSid
    )

    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or
        -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw 'La elevacion requiere ejecutar JWAD desde un archivo .ps1 local. No se admite la modalidad irm | iex.'
    }

    $hostExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf)) {
        $hostExe = Join-Path $PSHOME 'powershell.exe'
    }
    if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf)) {
        throw "No se encontro el ejecutable del host PowerShell: $PSHOME"
    }

    # Se ejecuta exactamente el archivo local actual y se espera su terminacion.
    $quotedScript = '"{0}"' -f $ScriptPath
    $quotedSid = '"{0}"' -f $ExpectedUserSid
    # Se conserva la politica efectiva y se verifica el mismo SID en el proceso elevado.
    $argumentLine = '-NoProfile -File {0} -ExpectedUserSid {1}' -f $quotedScript, $quotedSid
    $child = Start-Process -FilePath $hostExe -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
    return [int]$child.ExitCode
}

function Update-ProcessPath {
    [CmdletBinding()]
    param()

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    $combined = @($machinePath, $userPath, $windowsApps) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $items = foreach ($part in $combined) {
        foreach ($entry in ($part -split ';')) {
            $candidate = $entry.Trim()
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $candidate }
        }
    }
    $env:Path = ($items | Select-Object -Unique) -join ';'
}

function Get-CommandPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { return $null }
    if ($command.Source) { return [string]$command.Source }
    return [string]$command.Definition
}

function New-AppResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$Status,
        [string]$Version = 'N/A',
        [double]$ElapsedSeconds = 0,
        [AllowNull()][string]$ErrorMessage = $null,
        [AllowNull()][Nullable[int]]$ExitCode = $null
    )

    return [PSCustomObject]@{
        app_name = $AppName
        estado = $Status
        version_instalada = $Version
        tiempo_instalacion_segundos = [Math]::Round($ElapsedSeconds, 2)
        codigo_salida = $ExitCode
        error_mensaje = $ErrorMessage
    }
}

function Enter-JWADRunLock {
    [CmdletBinding()]
    param()

    $script:RunMutex = [System.Threading.Mutex]::new($false, 'Local\JWAD_Deployment_Lock')
    try {
        $script:OwnsRunMutex = $script:RunMutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # El proceso anterior termino abruptamente; el hilo actual adquiere el mutex.
        $script:OwnsRunMutex = $true
    }

    if (-not $script:OwnsRunMutex) {
        $script:RunMutex.Dispose()
        $script:RunMutex = $null
        throw 'Ya existe otra instancia JWAD en esta sesion. Se cancela para evitar instalaciones y reportes concurrentes.'
    }
}

function Exit-JWADRunLock {
    [CmdletBinding()]
    param()

    if ($script:OwnsRunMutex -and $null -ne $script:RunMutex) {
        try { $script:RunMutex.ReleaseMutex() } catch { }
        $script:OwnsRunMutex = $false
    }
    if ($null -ne $script:RunMutex) {
        $script:RunMutex.Dispose()
        $script:RunMutex = $null
    }
}

function Get-ReportObject {
    [CmdletBinding()]
    param()

    $elapsed = [Math]::Round($script:RunClock.Elapsed.TotalSeconds, 2)
    return [ordered]@{
        timestamp = (Get-Date -Format 'o')
        specs_computador = $script:Telemetry
        diagnosticos_temperatura = [ordered]@{
            zona_termica_acpi_c = $script:ThermalZoneC
            nota = 'La zona termica ACPI no representa necesariamente la temperatura fisica de la CPU.'
        }
        reporte_instalacion = [ordered]@{
            tiempo_transcurrido_segundos = $elapsed
            error_fatal = $script:FatalError
            resultado_aplicaciones = @($script:Results.ToArray())
        }
    }
}

function Save-IncrementalReport {
    [CmdletBinding()]
    param()

    $mutex = $null
    $ownsMutex = $false
    $tempFile = $null

    try {
        $directory = Split-Path -Parent $script:ReportPath
        if (-not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }

        # Mutex local a la sesion para impedir dos escrituras simultaneas del mismo reporte.
        $mutex = [System.Threading.Mutex]::new($false, 'Local\JWAD_Reporte_Despliegue')
        try {
            $ownsMutex = $mutex.WaitOne(15000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }
        if (-not $ownsMutex) {
            throw 'No se obtuvo el bloqueo de escritura del reporte dentro de 15 segundos.'
        }

        $report = Get-ReportObject
        $json = $report | ConvertTo-Json -Depth 8
        $tempFile = Join-Path $directory ('.Reporte_Despliegue.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempFile, $json, $encoding)

        # Replace conserva el archivo anterior si la sustitucion no se completa.
        if ([System.IO.File]::Exists($script:ReportPath)) {
            [System.IO.File]::Replace($tempFile, $script:ReportPath, $null)
        }
        else {
            [System.IO.File]::Move($tempFile, $script:ReportPath)
        }

        $script:ReportSaved = $true
        $script:ReportError = $null
        return $true
    }
    catch {
        $script:ReportSaved = $false
        $script:ReportError = $_.Exception.Message
        Write-Warning ("No se pudo guardar el reporte incremental: {0}" -f $_.Exception.Message)
        return $false
    }
    finally {
        if ($tempFile -and [System.IO.File]::Exists($tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        if ($ownsMutex -and $null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Add-AppResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result
    )

    $script:Results.Add($Result)
    [void](Save-IncrementalReport)
}

function Get-HttpStatusCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    try {
        if ($null -ne $ErrorRecord.Exception.Response) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch { }
    return 0
}

function Invoke-WebRequestBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [ValidateRange(5, 300)][int]$TimeoutSec = 60,
        [ValidateRange(1, 5)][int]$Attempts = 3
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $parameters = @{
                Uri = $Uri
                OutFile = $OutFile
                TimeoutSec = $TimeoutSec
                ErrorAction = 'Stop'
                Headers = @{ 'User-Agent' = 'JWAD-Windows-App-Deployer/4.0' }
            }
            if ($PSVersionTable.PSVersion.Major -eq 5) {
                $parameters.UseBasicParsing = $true
            }
            else {
                # PowerShell 7.4+ separa el timeout de conexion del timeout de lectura.
                $webCommand = Get-Command -Name Invoke-WebRequest -ErrorAction Stop
                if ($webCommand.Parameters.ContainsKey('OperationTimeoutSeconds')) {
                    $parameters.OperationTimeoutSeconds = $TimeoutSec
                }
            }
            Invoke-WebRequest @parameters | Out-Null

            if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
                throw 'La solicitud HTTP no genero el archivo de salida esperado.'
            }
            if ((Get-Item -LiteralPath $OutFile).Length -le 0) {
                throw 'El archivo descargado esta vacio.'
            }
            return
        }
        catch {
            if ($attempt -ge $Attempts) { throw }
            if (Test-Path -LiteralPath $OutFile) {
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            }
            $delay = [Math]::Min(8, [Math]::Pow(2, $attempt))
            Write-Warning ("Descarga fallida (intento {0}/{1}); nuevo intento en {2}s: {3}" -f $attempt, $Attempts, $delay, $_.Exception.Message)
            Start-Sleep -Seconds ([int]$delay)
        }
    }
}

function Get-GitHubLatestRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [ValidateRange(1, 5)][int]$Attempts = 3
    )

    $uri = 'https://api.github.com/repos/{0}/releases/latest' -f $Repository
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $parameters = @{
                Uri = $uri
                TimeoutSec = 30
                ErrorAction = 'Stop'
                Headers = @{
                    'User-Agent' = 'JWAD-Windows-App-Deployer/4.0'
                    'Accept' = 'application/vnd.github+json'
                }
            }
            if ($PSVersionTable.PSVersion.Major -eq 5) {
                $parameters.UseBasicParsing = $true
            }
            else {
                $webCommand = Get-Command -Name Invoke-RestMethod -ErrorAction Stop
                if ($webCommand.Parameters.ContainsKey('OperationTimeoutSeconds')) {
                    $parameters.OperationTimeoutSeconds = 30
                }
            }
            return Invoke-RestMethod @parameters
        }
        catch {
            $status = Get-HttpStatusCode -ErrorRecord $_
            $response = $null
            try { $response = $_.Exception.Response } catch { }
            $remaining = $null
            $retryAfter = 0
            $retryAfterHeader = $null
            $resetHeader = $null
            try { $remaining = [string]$response.Headers['X-RateLimit-Remaining'] } catch { }
            try { $retryAfterHeader = [string]$response.Headers['Retry-After'] } catch { }
            try { $resetHeader = [string]$response.Headers['X-RateLimit-Reset'] } catch { }

            if (-not [string]::IsNullOrWhiteSpace($retryAfterHeader)) {
                $parsedSeconds = 0
                if ([int]::TryParse($retryAfterHeader, [ref]$parsedSeconds)) {
                    $retryAfter = $parsedSeconds
                }
                else {
                    $retryDate = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse($retryAfterHeader, [ref]$retryDate)) {
                        $retryAfter = [int][Math]::Ceiling(($retryDate - [DateTimeOffset]::UtcNow).TotalSeconds)
                    }
                }
            }
            if ($retryAfter -le 0 -and -not [string]::IsNullOrWhiteSpace($resetHeader)) {
                $resetEpoch = 0L
                if ([long]::TryParse($resetHeader, [ref]$resetEpoch)) {
                    $resetDate = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch)
                    $retryAfter = [int][Math]::Ceiling(($resetDate - [DateTimeOffset]::UtcNow).TotalSeconds)
                }
            }

            $rateLimited = ($status -eq 429) -or ($status -eq 403 -and $remaining -eq '0')
            $transientServerError = ($status -ge 500 -and $status -le 599)
            if ((-not $rateLimited -and -not $transientServerError) -or $attempt -ge $Attempts) {
                throw
            }

            if ($rateLimited) {
                # No se reintenta antes de la ventana indicada por GitHub.
                # Si el servidor no informa una espera verificable o pide demasiado tiempo,
                # se aborta y se registra el fallo en vez de seguir golpeando la API.
                if ($retryAfter -le 0) {
                    throw 'GitHub aplico rate limit sin un Retry-After/X-RateLimit-Reset utilizable; se aborta sin reintentar.'
                }
                if ($retryAfter -gt 15) {
                    throw ("GitHub solicito esperar {0}s por rate limit; se aborta sin bloqueo prolongado." -f $retryAfter)
                }
                $delay = [Math]::Max(1, $retryAfter)
            }
            else {
                # Backoff exponencial limitado para errores HTTP 5xx transitorios.
                $delay = [int][Math]::Min(15, [Math]::Pow(2, $attempt))
            }
            Write-Warning ("GitHub respondio HTTP {0}; reintento {1}/{2} en {3}s." -f $status, $attempt, $Attempts, $delay)
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-InstallerProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyString()][string]$ArgumentLine = '',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentLine -PassThru -NoNewWindow -ErrorAction Stop
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Intenta terminar tambien los descendientes del instalador; Stop-Process queda como respaldo.
            $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
                try { & $taskkill /PID $process.Id /T /F 2>$null | Out-Null } catch { }
            }
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
            throw "TIMEOUT: el proceso supero $TimeoutSeconds segundos."
        }

        $process.Refresh()
        return [int]$process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-ProcessWithOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyString()][string]$ArgumentLine = '',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120
    )

    $stdoutPath = Join-Path $script:TempRoot ([Guid]::NewGuid().ToString('N') + '.stdout')
    $stderrPath = Join-Path $script:TempRoot ([Guid]::NewGuid().ToString('N') + '.stderr')
    $process = $null
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentLine -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
                try { & $taskkill /PID $process.Id /T /F 2>$null | Out-Null } catch { }
            }
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
            throw "TIMEOUT: el proceso de consulta supero $TimeoutSeconds segundos."
        }

        $process.Refresh()
        $stdout = if ([System.IO.File]::Exists($stdoutPath)) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
        $stderr = if ([System.IO.File]::Exists($stderrPath)) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
        return [PSCustomObject]@{
            ExitCode = [int]$process.ExitCode
            StandardOutput = $stdout
            StandardError = $stderr
            CombinedOutput = ($stdout + "`r`n" + $stderr)
        }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Show-JWADProgress {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 1000)][int]$Current,
        [ValidateRange(1, 1000)][int]$Total,
        [Parameter(Mandatory)][string]$Label
    )

    $width = 28
    $ratio = [Math]::Min(1.0, [Math]::Max(0.0, ($Current / [double]$Total)))
    $filled = [int][Math]::Round($width * $ratio)
    $empty = $width - $filled

    Write-Host ("`n  [{0,2}/{1,2}] {2}" -f $Current, $Total, $Label) -ForegroundColor Cyan
    Write-Host '  [' -ForegroundColor Blue -NoNewline
    if ($filled -gt 0) { Write-Host ('#' * $filled) -ForegroundColor Green -NoNewline }
    if ($empty -gt 0) { Write-Host ('.' * $empty) -ForegroundColor DarkBlue -NoNewline }
    Write-Host ('] {0}s transcurridos' -f [Math]::Round($script:RunClock.Elapsed.TotalSeconds, 1)) -ForegroundColor White
}

# -----------------------------------------------------------------------------
# WINGET Y BOOTSTRAPPER
# -----------------------------------------------------------------------------

function Install-AppxBundleBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string[]]$DependencyPaths,
        [ValidateRange(30, 900)][int]$TimeoutSeconds = 300
    )

    if ($DependencyPaths.Count -ne 2) {
        throw 'Se requieren exactamente dos paquetes de dependencia para este bootstrapper.'
    }

    # Ejecuta Add-AppxPackage en un proceso PowerShell separado y acotado por tiempo.
    # Se usa -EncodedCommand (sin crear archivos auxiliares ni cambiar ExecutionPolicy).
    # Los literales escapan apostrofes para no permitir inyeccion por rutas.
    $bundleLiteral = "'" + $BundlePath.Replace("'", "''") + "'"
    $dependencyOneLiteral = "'" + $DependencyPaths[0].Replace("'", "''") + "'"
    $dependencyTwoLiteral = "'" + $DependencyPaths[1].Replace("'", "''") + "'"
    $commandText = @"
`$ErrorActionPreference = 'Stop'
try {
    Add-AppxPackage -Path $bundleLiteral -DependencyPath @($dependencyOneLiteral, $dependencyTwoLiteral) -ErrorAction Stop
    exit 0
}
catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    exit 1
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
        $hostExe = $windowsPowerShell
    }
    else {
        $hostExe = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf)) {
            throw 'No se encontro un host PowerShell para ejecutar Add-AppxPackage.'
        }
    }

    $argumentLine = '-NoProfile -NonInteractive -EncodedCommand {0}' -f $encodedCommand
    $exitCode = Invoke-InstallerProcess -FilePath $hostExe -ArgumentLine $argumentLine -TimeoutSeconds $TimeoutSeconds
    if ($exitCode -ne 0) {
        throw "Add-AppxPackage devolvio un codigo de salida: $exitCode"
    }
}

function Install-WingetBootstrapper {
    [CmdletBinding()]
    param()

    Update-ProcessPath
    $existing = Get-CommandPath -Name 'winget.exe'
    if ($existing) {
        $script:WingetPath = $existing
        Write-Host '[OK] Winget detectado.' -ForegroundColor Green
        return $true
    }

    Write-Warning 'Winget no esta disponible. Se intentara instalar App Installer y sus dependencias.'
    $work = Join-Path $script:TempRoot ('JWAD-Winget-' + [Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($work)

    $xamlPath = Join-Path $work 'Microsoft.UI.Xaml.appx'
    $vcPath = Join-Path $work 'Microsoft.VCLibs.appx'
    $bundlePath = Join-Path $work 'Microsoft.DesktopAppInstaller.msixbundle'

    try {
        $xamlUrl = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'
        $vcUrl = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
        $wingetUrl = 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'

        Invoke-WebRequestBounded -Uri $xamlUrl -OutFile $xamlPath -TimeoutSec 90
        Invoke-WebRequestBounded -Uri $vcUrl -OutFile $vcPath -TimeoutSec 90
        Invoke-WebRequestBounded -Uri $wingetUrl -OutFile $bundlePath -TimeoutSec 120

        # El proceso auxiliar aplica un limite temporal y Add-AppxPackage valida la firma.
        Install-AppxBundleBounded -BundlePath $bundlePath -DependencyPaths @($xamlPath, $vcPath) -TimeoutSeconds 300
        Update-ProcessPath
        $script:WingetPath = Get-CommandPath -Name 'winget.exe'
        if (-not $script:WingetPath) {
            throw 'App Installer se proceso, pero winget.exe no se puede resolver en este contexto.'
        }
        Write-Host '[OK] App Installer/Winget instalado.' -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning ("Bootstrapper de Winget no disponible: {0}" -f $_.Exception.Message)
        $script:WingetPath = $null
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-AppViaWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$WingetId
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("`n[*] Instalando {0} ({1}) mediante Winget..." -f $AppName, $WingetId) -ForegroundColor Blue

    try {
        if (-not $script:WingetPath) {
            throw 'Winget no esta disponible. No se puede ejecutar esta instalacion.'
        }

        # Primero se comprueba el estado instalado. Si la consulta falla, no se
        # presupone que la aplicacion no exista ni se intenta una reinstalacion a ciegas.
        $listArguments = 'list --id "{0}" --exact --accept-source-agreements --disable-interactivity' -f $WingetId
        $listResult = Invoke-ProcessWithOutput -FilePath $script:WingetPath -ArgumentLine $listArguments -TimeoutSeconds 120
        if ($listResult.ExitCode -ne 0) {
            throw ("No fue posible verificar el estado de {0} con winget list (exit {1}): {2}" -f $AppName, $listResult.ExitCode, $listResult.CombinedOutput.Trim())
        }

        $idPattern = '(?im)^.*\b' + [regex]::Escape($WingetId) + '\b.*$'
        $isInstalled = [regex]::IsMatch($listResult.CombinedOutput, $idPattern)
        if ($isInstalled) {
            $arguments = 'upgrade --id "{0}" --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --architecture x64' -f $WingetId
            $operation = 'actualizacion'
        }
        else {
            $arguments = 'install --id "{0}" --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --architecture x64' -f $WingetId
            $operation = 'instalacion'
        }

        $exitCode = Invoke-InstallerProcess -FilePath $script:WingetPath -ArgumentLine $arguments -TimeoutSeconds 900
        if ($isInstalled -and $exitCode -eq -1978335189) {
            # UPDATE_NOT_APPLICABLE solo se trata como instalacion existente porque
            # winget list confirmo antes el identificador exacto. No se afirma que
            # esto demuestre la version mas reciente; se conserva el matiz en el estado.
            $clock.Stop()
            Write-Host ("[OK] {0}: instalado; Winget no detecta una actualizacion aplicable." -f $AppName) -ForegroundColor Green
            return (New-AppResult -AppName $AppName -Status 'INSTALLED_NO_UPDATE_APPLICABLE' -Version 'Sin actualizacion aplicable' -ElapsedSeconds $clock.Elapsed.TotalSeconds -ExitCode $exitCode)
        }
        if ($exitCode -ne 0) {
            throw "Winget devolvio un codigo de salida no reconocido como exito durante ${operation}: $exitCode"
        }

        $clock.Stop()
        Write-Host ("[OK] {0}: {1} confirmada por codigo 0." -f $AppName, $operation) -ForegroundColor Green
        return (New-AppResult -AppName $AppName -Status 'INSTALLED' -Version 'Gestionado por Winget' -ElapsedSeconds $clock.Elapsed.TotalSeconds -ExitCode $exitCode)
    }
    catch {
        $clock.Stop()
        Write-Warning ("[FALLO] {0}: {1}" -f $AppName, $_.Exception.Message)
        return (New-AppResult -AppName $AppName -Status 'FAILED' -ElapsedSeconds $clock.Elapsed.TotalSeconds -ErrorMessage $_.Exception.Message)
    }
}

# -----------------------------------------------------------------------------
# INSTALADORES PUBLICADOS EN GITHUB
# -----------------------------------------------------------------------------
function Install-AppViaGitHubRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AssetFilter
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $installerPath = $null

    Write-Host ("`n[*] Consultando release de {0} ({1})..." -f $AppName, $Repository) -ForegroundColor Blue
    try {
        $release = Get-GitHubLatestRelease -Repository $Repository -Attempts 3
        if (-not $release.tag_name -or -not $release.assets) {
            throw 'La respuesta de GitHub no contiene tag o assets utilizables.'
        }

        $remoteVersionText = ([string]$release.tag_name).Trim() -replace '^[vV]', ''
        $uninstallPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $installedEntry = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and (($_.DisplayName -replace '\s', '') -like ('*' + ($AppName -replace '\s', '') + '*')) } |
            Select-Object -First 1

        if ($null -ne $installedEntry) {
            if (-not $installedEntry.PSObject.Properties['DisplayVersion'] -or [string]::IsNullOrWhiteSpace([string]$installedEntry.DisplayVersion)) {
                throw 'SIN INFORMACION: la aplicacion ya aparece instalada, pero el registro no contiene DisplayVersion; se evita sobrescribirla sin comparar versiones.'
            }
            $localVersionText = ([string]$installedEntry.DisplayVersion).Trim() -replace '^[vV]', ''
            $remoteVersion = $null
            $localVersion = $null
            $remoteVersionValid = [version]::TryParse($remoteVersionText, [ref]$remoteVersion)
            $localVersionValid = [version]::TryParse($localVersionText, [ref]$localVersion)

            if ($remoteVersionValid -and $localVersionValid -and $localVersion -lt [version]'2.6.0') {
                throw 'La version local de FlyPhotos es anterior a 2.6.0. El fabricante indica que el in-place upgrade MSI no es aplicable a versiones antiguas; se requiere desinstalacion previa controlada.'
            }
            if ($remoteVersionValid -and $localVersionValid -and $localVersion -ge $remoteVersion) {
                $clock.Stop()
                Write-Host ("[OK] {0}: la version instalada ({1}) no es inferior a la publicada ({2})." -f $AppName, $localVersionText, $remoteVersionText) -ForegroundColor Green
                return (New-AppResult -AppName $AppName -Status 'YA_ACTUALIZADO' -Version $localVersionText -ElapsedSeconds $clock.Elapsed.TotalSeconds)
            }
            if (-not ($remoteVersionValid -and $localVersionValid) -and $localVersionText -ceq $remoteVersionText) {
                $clock.Stop()
                return (New-AppResult -AppName $AppName -Status 'YA_ACTUALIZADO' -Version $localVersionText -ElapsedSeconds $clock.Elapsed.TotalSeconds)
            }
            if (-not ($remoteVersionValid -and $localVersionValid)) {
                throw 'SIN INFORMACION: no se pueden comparar de forma fiable la version local y la version del release; se evita una posible reinstalacion o downgrade.'
            }
        }

        # Solo se acepta exactamente un MSI x64; los EXE quedan excluidos por depender
        # de switches silenciosos particulares del fabricante.
        $candidates = @($release.assets | Where-Object {
            $extension = [System.IO.Path]::GetExtension([string]$_.name)
            # Se aceptan unicamente MSI: su modo silencioso se controla con msiexec /qn.
            # Los EXE requieren switches especificos del fabricante; sin prueba documental se abortan.
            $isInstaller = ($extension -ieq '.msi')
            $isX64 = ([string]$_.name -match '(?i)(x64|win64|amd64|x86_64)')
            $matchesFilter = if ([string]::IsNullOrWhiteSpace($AssetFilter)) { $true } else { ([string]$_.name -like ('*' + $AssetFilter + '*')) }
            $notOtherArch = ([string]$_.name -notmatch '(?i)(arm|aarch64|mac|linux|x86(?!_64))')
            $isInstaller -and $isX64 -and $matchesFilter -and $notOtherArch
        })

        if ($candidates.Count -ne 1) {
            throw ("SIN INFORMACION: se esperaba exactamente un MSI x64 para el filtro '{0}', encontrados: {1}. No se seleccionara un asset ambiguo." -f $AssetFilter, $candidates.Count)
        }

        $asset = $candidates[0]
        if ([string]$asset.state -ne 'uploaded') {
            throw 'El asset de GitHub no esta marcado como uploaded.'
        }
        if ([string]$asset.browser_download_url -notmatch '^https://github\.com/') {
            throw 'La URL de descarga no pertenece al dominio HTTPS esperado github.com.'
        }

        # GitHub publica digest SHA-256 en los metadatos de release assets.
        if ([string]$asset.digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
            throw 'SIN INFORMACION: GitHub no publico un digest SHA-256 verificable para este asset; instalacion cancelada.'
        }

        $fileName = [System.IO.Path]::GetFileName([string]$asset.name)
        $installerPath = Join-Path $script:TempRoot ([Guid]::NewGuid().ToString('N') + '-' + $fileName)
        Invoke-WebRequestBounded -Uri ([uri]$asset.browser_download_url) -OutFile $installerPath -TimeoutSec 180

        $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
        $expectedHash = ([string]$asset.digest -replace '^sha256:', '').ToUpperInvariant()
        if ($actualHash.ToUpperInvariant() -ne $expectedHash) {
            throw 'La verificacion SHA-256 del instalador descargado fallo.'
        }

        $extension = [System.IO.Path]::GetExtension($installerPath)
        if ($extension -ieq '.msi') {
            $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
            $arguments = '/i "{0}" /qn /norestart' -f $installerPath
            $exitCode = Invoke-InstallerProcess -FilePath $msiexec -ArgumentLine $arguments -TimeoutSeconds 600
            $successCodes = @(0, 3010)
        }
        else {
            throw "SIN INFORMACION: solo se ejecutan MSI con msiexec /qn; los instaladores EXE requieren parametros silenciosos validados por el fabricante."
        }

        if ($successCodes -notcontains $exitCode) {
            throw "El instalador devolvio un codigo de salida no reconocido como exito: $exitCode"
        }

        $clock.Stop()
        $status = if ($exitCode -eq 3010) { 'INSTALLED_REBOOT_REQUIRED' } else { 'INSTALLED' }
        Write-Host ("[OK] {0}: {1}." -f $AppName, $status) -ForegroundColor Green
        return (New-AppResult -AppName $AppName -Status $status -Version ([string]$release.tag_name) -ElapsedSeconds $clock.Elapsed.TotalSeconds -ExitCode $exitCode)
    }
    catch {
        $clock.Stop()
        Write-Warning ("[FALLO] {0}: {1}" -f $AppName, $_.Exception.Message)
        return (New-AppResult -AppName $AppName -Status 'FAILED' -ElapsedSeconds $clock.Elapsed.TotalSeconds -ErrorMessage $_.Exception.Message)
    }
    finally {
        if ($installerPath -and (Test-Path -LiteralPath $installerPath)) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# -----------------------------------------------------------------------------
# TELEMETRIA: WMI/CIM ES OPCIONAL; REGISTRO Y .NET SON LAS ALTERNATIVAS
# -----------------------------------------------------------------------------
function Get-SystemTelemetry {
    [CmdletBinding()]
    param()

    $bios = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue
    if ($bios) {
        if ($bios.PSObject.Properties['SystemManufacturer'] -and $bios.SystemManufacturer) {
            $script:Telemetry.fabricante = [string]$bios.SystemManufacturer
        }
        if ($bios.PSObject.Properties['SystemProductName'] -and $bios.SystemProductName) {
            $script:Telemetry.modelo = [string]$bios.SystemProductName
        }
    }

    $cpu = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue
    if ($cpu -and $cpu.PSObject.Properties['ProcessorNameString'] -and $cpu.ProcessorNameString) {
        $script:Telemetry.procesador = ([string]$cpu.ProcessorNameString).Trim()
    }

    # Las consultas CIM se ejecutan individualmente: un proveedor ausente no detiene la telemetria restante.
    $computerSystem = $null
    $operatingSystem = $null
    try { $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop } catch { }
    try { $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop } catch { }

    if ($computerSystem) {
        if ($computerSystem.Manufacturer -and $script:Telemetry.fabricante -eq 'No disponible') {
            $script:Telemetry.fabricante = [string]$computerSystem.Manufacturer
        }
        if ($computerSystem.Model -and $script:Telemetry.modelo -eq 'No disponible') {
            $script:Telemetry.modelo = [string]$computerSystem.Model
        }
        if ($computerSystem.TotalPhysicalMemory -gt 0) {
            $script:Telemetry.memoria_ram_total_gb = [Math]::Round(([double]$computerSystem.TotalPhysicalMemory / 1GB), 2)
        }
    }

    if ($operatingSystem -and $operatingSystem.TotalVisibleMemorySize -gt 0) {
        $totalKb = [double]$operatingSystem.TotalVisibleMemorySize
        $freeKb = [double]$operatingSystem.FreePhysicalMemory
        $script:Telemetry.uso_actual_ram_porcentaje = [Math]::Round((($totalKb - $freeKb) / $totalKb) * 100, 2)
        if ($null -eq $script:Telemetry.memoria_ram_total_gb) {
            $script:Telemetry.memoria_ram_total_gb = [Math]::Round(($totalKb / 1MB), 2)
        }
    }

    # DriveInfo evita depender de Win32_LogicalDisk para el almacenamiento local.
    try {
        $drive = [System.IO.DriveInfo]::new('C:\')
        if ($drive.IsReady -and $drive.TotalSize -gt 0) {
            $totalGb = [double]$drive.TotalSize / 1GB
            $freeGb = [double]$drive.AvailableFreeSpace / 1GB
            $script:Telemetry.almacenamiento_total_gb = [Math]::Round($totalGb, 2)
            $script:Telemetry.uso_actual_almacenamiento_porcentaje = [Math]::Round((($totalGb - $freeGb) / $totalGb) * 100, 2)
        }
    }
    catch {
        Write-Warning ("No se pudo consultar el volumen C: mediante DriveInfo: {0}" -f $_.Exception.Message)
    }

    # La clase ACPI puede no existir, estar deshabilitada o no exponer datos fiables.
    try {
        $thermal = Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -OperationTimeoutSec 10 -ErrorAction Stop |
            Select-Object -First 1
        if ($null -ne $thermal -and $thermal.CurrentTemperature -gt 0) {
            $script:ThermalZoneC = [Math]::Round((([double]$thermal.CurrentTemperature - 2732) / 10), 2)
        }
    }
    catch {
        $script:ThermalZoneC = $null
    }
}

function Test-NetFramework48 {
    [CmdletBinding()]
    param()

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop
        $release = [int]$key.Release
        $status = if ($release -ge 528040) { 'YA_ACTUALIZADO' } else { 'DESACTUALIZADO' }
        $version = 'Release {0}' -f $release
        $clock.Stop()
        return (New-AppResult -AppName '.NET Framework 4.8+' -Status $status -Version $version -ElapsedSeconds $clock.Elapsed.TotalSeconds)
    }
    catch {
        $clock.Stop()
        return (New-AppResult -AppName '.NET Framework 4.8+' -Status 'NO_DETECTADO' -ElapsedSeconds $clock.Elapsed.TotalSeconds -ErrorMessage $_.Exception.Message)
    }
}

# -----------------------------------------------------------------------------
# VALIDACION DE PLATAFORMA Y ELEVACION
# -----------------------------------------------------------------------------
Write-JWADBanner

if ($PSVersionTable.PSVersion.Major -eq 6) {
    Write-Error 'PowerShell 6 no forma parte de la matriz de compatibilidad; use Windows PowerShell 5.1 o PowerShell 7+.' -ErrorAction Continue
    exit 2
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Error 'Este despliegue solo admite Windows NT.' -ErrorAction Continue
    exit 2
}
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error 'Este despliegue requiere Windows x64.' -ErrorAction Continue
    exit 2
}
if (-not [Environment]::Is64BitProcess) {
    Write-Error 'Ejecute el script desde PowerShell x64, no desde un host de 32 bits.' -ErrorAction Continue
    exit 2
}

try {
    $osInfo = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ($osInfo.ProductName -match 'Server') {
        throw 'El sistema detectado es Windows Server; este script esta definido para Windows 10/11 cliente.'
    }
    if ([Environment]::OSVersion.Version.Major -ne 10) {
        throw ("Version de Windows no validada para este despliegue: {0}" -f [Environment]::OSVersion.Version)
    }
    if ([int]$osInfo.CurrentBuildNumber -lt 17763) {
        throw ("Se requiere Windows 10 version 1809 (build 17763) o posterior. Build detectado: {0}" -f $osInfo.CurrentBuildNumber)
    }
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 2
}

$currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not [string]::IsNullOrWhiteSpace($ExpectedUserSid) -and $ExpectedUserSid -ne $currentUserSid) {
    Write-Error 'La elevacion cambio la identidad del usuario. Se cancela para evitar instalar paquetes por usuario en el perfil equivocado.' -ErrorAction Continue
    exit 5
}

if (-not (Test-IsAdministrator)) {
    Write-Warning 'Se requieren privilegios de administrador. Se solicitara UAC y se esperara el proceso elevado.'
    try {
        $childExitCode = Start-ElevatedRelaunch -ScriptPath $PSCommandPath -ExpectedUserSid $currentUserSid
        exit $childExitCode
    }
    catch {
        Write-Error ("No se pudo completar la elevacion UAC. No se inicio el despliegue: {0}" -f $_.Exception.Message) -ErrorAction Continue
        exit 5
    }
}

# TLS 1.2 se agrega sin retirar protocolos habilitados por el sistema en Windows PowerShell 5.1.
# En PowerShell 7+ el stack HTTP moderno usa la configuracion TLS de .NET/Windows.
if ($PSVersionTable.PSVersion.Major -eq 5) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = ([Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12)
    }
    catch {
        Write-Warning ("No se pudo ajustar TLS 1.2 explicitamente: {0}" -f $_.Exception.Message)
    }
}

try {
    Enter-JWADRunLock
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 6
}

# -----------------------------------------------------------------------------
# DESPLIEGUE PRINCIPAL
# -----------------------------------------------------------------------------
$step = 0
$totalSteps = 14

try {
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ' PREPARANDO ENTORNO DE DESPLIEGUE' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan

    $wingetReady = Install-WingetBootstrapper
    if (-not $wingetReady) {
        Write-Warning 'Las aplicaciones dependientes de Winget quedaran como FAILED; se continuara con el resto del flujo.'
    }

    Write-Host "`nINSTALANDO COMPLEMENTOS" -ForegroundColor Cyan

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'Visual C++ Redistributable x64'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'Visual C++ Redistributable x64' -WingetId 'Microsoft.VCRedist.2015+.x64')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label '.NET Framework 4.8+ (validacion)'
    Add-AppResult -Result (Test-NetFramework48)

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'Java Runtime Environment x64'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'Java Runtime Environment' -WingetId 'EclipseAdoptium.Temurin.21.JRE')

    Write-Host "`nINSTALANDO APLICACIONES PRINCIPALES" -ForegroundColor Cyan

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label '7-Zip'
    Add-AppResult -Result (Install-AppViaWinget -AppName '7-Zip' -WingetId '7zip.7zip')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'Bulk Crap Uninstaller'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'Bulk Crap Uninstaller' -WingetId 'Klocman.BulkCrapUninstaller')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'SumatraPDF'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'SumatraPDF' -WingetId 'SumatraPDF.SumatraPDF')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'AB Download Manager'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'AB Download Manager' -WingetId 'amir1376.ABDownloadManager')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'WinRAR x64'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'WinRAR x64' -WingetId 'RARLab.WinRAR')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'VLC Media Player'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'VLC Media Player' -WingetId 'VideoLAN.VLC')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'Google Chrome'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'Google Chrome' -WingetId 'Google.Chrome')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'Mozilla Firefox'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'Mozilla Firefox' -WingetId 'Mozilla.Firefox')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'Mullvad Browser'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'Mullvad Browser' -WingetId 'MullvadVPN.MullvadBrowser')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'Microsoft Edge'
    Add-AppResult -Result (Install-AppViaWinget -AppName 'Microsoft Edge' -WingetId 'Microsoft.Edge')

    $step++; Show-JWADProgress -Current $step -Total $totalSteps -Label 'FlyPhotos'
    Add-AppResult -Result (Install-AppViaGitHubRelease -AppName 'FlyPhotos' -Repository 'riyasy/FlyPhotos' -AssetFilter '')

    Write-Host "`nRECOPILANDO TELEMETRIA" -ForegroundColor Cyan
    Get-SystemTelemetry
}
catch {
    $script:FatalError = $_.Exception.Message
    Write-Warning ("Error no recuperable en el flujo principal: {0}" -f $script:FatalError)
}
finally {
    $script:RunClock.Stop()
    [void](Save-IncrementalReport)

    Write-Host "`n=========================================================" -ForegroundColor Green
    Write-Host ' REPORTE FINAL DE DESPLIEGUE' -ForegroundColor Green
    Write-Host '=========================================================' -ForegroundColor Green
    Write-Host ("Equipo: {0} {1}" -f $script:Telemetry.fabricante, $script:Telemetry.modelo)
    Write-Host ("Procesador: {0}" -f $script:Telemetry.procesador)
    Write-Host ("RAM total: {0} GB | Uso: {1}%" -f $script:Telemetry.memoria_ram_total_gb, $script:Telemetry.uso_actual_ram_porcentaje)
    Write-Host ("Disco C: total: {0} GB | Uso: {1}%" -f $script:Telemetry.almacenamiento_total_gb, $script:Telemetry.uso_actual_almacenamiento_porcentaje)

    if ($null -ne $script:ThermalZoneC) {
        Write-Host ("Zona termica ACPI: {0} C (no equivale necesariamente a CPU)" -f $script:ThermalZoneC) -ForegroundColor Yellow
    }
    else {
        Write-Host 'Zona termica ACPI: No disponible' -ForegroundColor Gray
    }

    Write-Host ("Tiempo total: {0}s" -f [Math]::Round($script:RunClock.Elapsed.TotalSeconds, 2)) -ForegroundColor Cyan
    if ($script:ReportSaved) {
        Write-Host ("Reporte JSON guardado: {0}" -f $script:ReportPath) -ForegroundColor Green
    }
    else {
        Write-Warning ("REPORTE NO CONFIRMADO: {0}" -f $script:ReportError)
    }

    Write-Host "`nEstado de instalaciones:" -ForegroundColor Gray
    foreach ($app in $script:Results) {
        $color = if ($app.estado -eq 'FAILED' -or $app.estado -eq 'NO_DETECTADO') { 'Red' }
            elseif ($app.estado -eq 'DESACTUALIZADO') { 'Yellow' }
            else { 'Green' }
        Write-Host ("  [{0}] {1} | Version: {2} | Tiempo: {3}s | ExitCode: {4}" -f $app.estado, $app.app_name, $app.version_instalada, $app.tiempo_instalacion_segundos, $app.codigo_salida) -ForegroundColor $color
    }
    Write-Host '=========================================================' -ForegroundColor Green
    Exit-JWADRunLock
}

$problemStatuses = @('FAILED', 'NO_DETECTADO', 'DESACTUALIZADO')
$problemCount = @($script:Results | Where-Object { $problemStatuses -contains $_.estado }).Count
$rebootRequiredCount = @($script:Results | Where-Object { $_.estado -eq 'INSTALLED_REBOOT_REQUIRED' }).Count

if ($script:FatalError -or -not $script:ReportSaved -or $problemCount -gt 0) {
    exit 1
}
if ($rebootRequiredCount -gt 0) {
    exit 3010
}
exit 0
