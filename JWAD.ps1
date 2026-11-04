#requires -Version 5.1
<#
JWAD - Windows App Deployer
Version: 3.2.0 (accurate up-to-date states, resilient direct resolvers, ASCII console)
Compatibilidad objetivo: Windows 10/11 x64; Windows PowerShell 5.1 y PowerShell 7+

IMPORTANTE:
- Ejecutar preferentemente como archivo local, despues de revisar su contenido.
- No se cambian politicas de ejecucion de forma persistente.
- Scoop se instala por usuario. Si el proceso esta elevado, el bootstrap de Scoop
  requiere autorizacion explicita mediante JWAD_ALLOW_SCOOP_ADMIN=1.
- El fallback directo solo funciona cuando la aplicacion tiene una fuente, un
  patron de asset y argumentos silenciosos verificados/configurados.
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
$script:JWADVersion = '3.2.0'
$script:JWADStarted = [System.Diagnostics.Stopwatch]::StartNew()
$script:JWADIsAdmin = $false
$script:ScoopBootstrapAttempted = $false
$script:ScoopBootstrapSucceeded = $false
$script:ScoopBootstrapFailureReason = ''
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

# Windows PowerShell 5.1 en .NET Framework antiguo puede requerir TLS 1.2 explicito.
# PowerShell 7 conserva el protocolo seguro predeterminado del sistema.
if ($PSVersionTable.PSVersion.Major -eq 5) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # La conectividad HTTPS podra fallar posteriormente y sera capturada por el fallback.
    }
}

# -----------------------------------------------------------------------------
# TEXT NORMALIZATION AND INSTALLED-APP DETECTION
# -----------------------------------------------------------------------------
function ConvertTo-JWADAsciiText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return '' }

    # Recover common UTF-8-as-Windows-1252 mojibake from localized native errors.
    # Convert only when a typical mojibake marker is present; all final console
    # and log text is then transliterated to plain ASCII.
    if ($Text -match '[\u00C3\u00C2][\u0080-\u00BF]') {
        try {
            $recovered = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(1252).GetBytes($Text))
            if ($recovered -notmatch '\uFFFD') { $Text = $recovered }
        }
        catch { }
    }
    $Text = $Text.Replace([string][char]0x00A0, ' ').Replace([string][char]0x00AD, '')
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark -and
            $category -ne [Globalization.UnicodeCategory]::SpacingCombiningMark -and
            $category -ne [Globalization.UnicodeCategory]::EnclosingMark) {
            [void]$builder.Append($character)
        }
    }
    $value = $builder.ToString()
    $value = $value.Replace([string][char]0x2013, '-').Replace([string][char]0x2014, '-')
    $value = $value.Replace([string][char]0x2018, "'").Replace([string][char]0x2019, "'")
    $value = $value.Replace([string][char]0x201C, '"').Replace([string][char]0x201D, '"')
    $value = $value.Replace([string][char]0x2192, '->').Replace([string][char]0x2022, '-')
    return [regex]::Replace($value, '[^\x00-\x7F]', '?')
}

function Get-JWADInstalledApplication {
    [CmdletBinding()]
    param([string]$DisplayNamePattern)

    if ([string]::IsNullOrWhiteSpace($DisplayNamePattern)) { return $null }
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        $entries = @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)
        foreach ($entry in $entries) {
            $displayName = [string]$entry.DisplayName
            if (-not [string]::IsNullOrWhiteSpace($displayName) -and $displayName -match $DisplayNamePattern) {
                return [PSCustomObject]@{
                    DisplayName = $displayName
                    DisplayVersion = [string]$entry.DisplayVersion
                    Publisher = [string]$entry.Publisher
                    RegistryKey = [string]$entry.PSPath
                }
            }
        }
    }
    return $null
}

function Get-JWADVCRuntimeInfo {
    [CmdletBinding()]
    param()

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )
    foreach ($path in $paths) {
        $runtime = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($runtime -and [int]$runtime.Installed -eq 1) {
            $version = [string]$runtime.Version
            if ([string]::IsNullOrWhiteSpace($version)) {
                $version = '{0}.{1}.{2}.{3}' -f $runtime.Major, $runtime.Minor, $runtime.Bld, $runtime.Rbld
            }
            return [PSCustomObject]@{ Installed = $true; Version = $version; RegistryPath = $path }
        }
    }
    return $null
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
    $safeMessage = ConvertTo-JWADAsciiText -Text $Message
    $line = '[{0}] {1}' -f $Level, $safeMessage
    Write-Host $line -ForegroundColor $color
    try {
        Add-Content -LiteralPath $script:LogPath -Value ('{0} {1}' -f (Get-Date -Format 'o'), $line) -Encoding ASCII
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
    # para evitar romper el limite entre argumentos.
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
        # Leer stdout/stderr de forma asincrona evita bloquear el proceso si llena los buffers.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [int][Math]::Min([int]::MaxValue, ($TimeoutSeconds * 1000))
        if (-not $process.WaitForExit($timeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            throw ('Tiempo maximo agotado ({0}s): {1}' -f $TimeoutSeconds, $FilePath)
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
        detalle      = (ConvertTo-JWADAsciiText -Text $Message)
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
        error_mensaje               = (ConvertTo-JWADAsciiText -Text $ErrorMessage)
    }
}

# -----------------------------------------------------------------------------
# NIVEL 1: WINGET
# -----------------------------------------------------------------------------
function Get-JWADWingetInstalledPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WingetId)

    $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue }
    if (-not $command) { return $null }

    $arguments = 'list --id {0} --exact --accept-source-agreements' -f (ConvertTo-JWADQuotedArgument $WingetId)
    $result = Invoke-JWADProcess -FilePath $command.Source -ArgumentList $arguments -TimeoutSeconds 60
    $output = ('{0}{1}{2}' -f [string]$result.Output, [Environment]::NewLine, [string]$result.Error)
    if ($result.ExitCode -ne 0 -or $output -match '(?i)No installed package found|No package found') { return $null }

    # Require the exact package ID as a whitespace-delimited table token; do not
    # infer installation from an error message that merely echoes the query.
    $idPattern = '(?<![A-Za-z0-9_.-])' + [regex]::Escape($WingetId) + '(?![A-Za-z0-9_.-])'
    foreach ($line in ($output -split '[`r`n]+')) {
        if ($line -match $idPattern) {
            $displayVersion = 'N/A'
            $idIndex = $line.IndexOf($WingetId, [StringComparison]::OrdinalIgnoreCase)
            if ($idIndex -ge 0) {
                $remainingColumns = $line.Substring($idIndex + $WingetId.Length).Trim()
                $versionToken = ($remainingColumns -split '\s+')[0]
                if ($versionToken -match '^\d+(?:\.\d+)+(?:[-+._][A-Za-z0-9.-]+)?$') { $displayVersion = $versionToken }
            }
            return [PSCustomObject]@{ DisplayName = $WingetId; DisplayVersion = $displayVersion; Source = 'WinGet list --id --exact' }
        }
    }
    return $null
}

function Invoke-JWADWingetInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WingetId,
        [string]$CustomArguments = '',
        [string]$DetectPattern = ''
    )

    $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue
    }
    if (-not $command) {
        throw 'Winget is not installed or is not available in PATH.'
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
    $combinedOutput = ('{0}{1}{2}' -f [string]$processResult.Output, [Environment]::NewLine, [string]$processResult.Error).Trim()
    if ($combinedOutput.Length -gt 2000) { $combinedOutput = $combinedOutput.Substring(0, 2000) }

    if ($processResult.ExitCode -eq 0) {
        $detected = Get-JWADInstalledApplication -DisplayNamePattern $DetectPattern
        $version = if ($detected) { $detected.DisplayVersion } else { 'N/A' }
        return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED'; ExitCode = 0; Version = $version; Detail = 'Winget completed successfully.' }
    }
    if ($processResult.ExitCode -in @(3010, 1641, -1978334965)) {
        $detected = Get-JWADInstalledApplication -DisplayNamePattern $DetectPattern
        $version = if ($detected) { $detected.DisplayVersion } else { 'N/A' }
        return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED_REBOOT_REQUIRED'; ExitCode = $processResult.ExitCode; Version = $version; Detail = 'Winget completed; a restart is required or was initiated.' }
    }

    # Official WinGet code 0x8A15002B / -1978335189 means UPDATE_NOT_APPLICABLE.
    # Mark it green only when the installed application is independently found.
    if ($processResult.ExitCode -eq -1978335189) {
        $detected = Get-JWADInstalledApplication -DisplayNamePattern $DetectPattern
        if (-not $detected) { $detected = Get-JWADWingetInstalledPackage -WingetId $WingetId }
        if ($detected) {
            $confirmationSource = 'Windows Uninstall registry'
            if ($detected.PSObject.Properties['Source']) { $confirmationSource = [string]$detected.Source }
            return [PSCustomObject]@{
                Success = $true; Status = 'UP_TO_DATE'; ExitCode = $processResult.ExitCode
                Version = $detected.DisplayVersion
                Detail = ('No applicable update was offered by WinGet; installed package confirmed through {0}: {1}.' -f $confirmationSource, $detected.DisplayName)
            }
        }
        throw ('WinGet returned UPDATE_NOT_APPLICABLE (0x8A15002B), but the local registry detector did not confirm the application. {0}' -f $combinedOutput)
    }

    # Already-installed / downgrade codes are also cross-checked locally.
    if ($processResult.ExitCode -in @(-1978334963, -1978335135, -1978334962)) {
        $detected = Get-JWADInstalledApplication -DisplayNamePattern $DetectPattern
        if (-not $detected) { $detected = Get-JWADWingetInstalledPackage -WingetId $WingetId }
        if ($detected) {
            $confirmationSource = 'Windows Uninstall registry'
            if ($detected.PSObject.Properties['Source']) { $confirmationSource = [string]$detected.Source }
            return [PSCustomObject]@{
                Success = $true; Status = 'ALREADY_PRESENT'; ExitCode = $processResult.ExitCode
                Version = $detected.DisplayVersion
                Detail = ('WinGet reports an existing package; confirmation source: {0}; package: {1}.' -f $confirmationSource, $detected.DisplayName)
            }
        }
        throw ('WinGet returned an already-installed/downgrade code, but registry detection did not confirm the application. ExitCode={0}. {1}' -f $processResult.ExitCode, $combinedOutput)
    }

    $detail = ('Winget ExitCode={0}. {1}' -f $processResult.ExitCode, $combinedOutput).Trim()
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'Winget returned a non-zero exit code.' }
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
    if (-not $cmd) { throw 'El comando scoop no esta disponible.' }

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
        throw ('El bootstrap de Scoop ya fallo en esta ejecucion. Causa original: {0}' -f $script:ScoopBootstrapFailureReason)
    }
    $script:ScoopBootstrapAttempted = $true

    if ($null -ne (Get-JWADScoopCommand)) {
        $script:ScoopCommand = Get-JWADScoopCommand
        $script:ScoopBootstrapSucceeded = $true
        return
    }

    $policy = Get-ExecutionPolicy
    if ($policy.ToString() -in @('Restricted', 'AllSigned')) {
        throw ('ExecutionPolicy efectiva={0}; no se intentara eludirla. Configure una politica autorizada o use el fallback directo.' -f $policy)
    }

    if ($script:JWADIsAdmin -and $env:JWAD_ALLOW_SCOOP_ADMIN -ne '1') {
        throw 'La consola esta elevada. Scoop no se instalara como administrador sin autorizacion explicita. Defina JWAD_ALLOW_SCOOP_ADMIN=1 si acepta ese modo.'
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
        throw 'La respuesta del instalador de Scoop esta vacia o no parece un script valido.'
    }

    # El patron & { script } refleja el procedimiento oficial de Scoop y permite
    # pasar -RunAsAdmin solo cuando se autorizo expresamente.
    $invocation = "& {`n$installerText`n}"
    if ($script:JWADIsAdmin) { $invocation += ' -RunAsAdmin' }
    Invoke-Expression $invocation | Out-Null

    $script:ScoopCommand = Get-JWADScoopCommand
    if (-not $script:ScoopCommand) {
        throw 'El instalador de Scoop termino, pero el comando scoop no quedo disponible.'
    }
    $script:ScoopBootstrapSucceeded = $true
}

function Invoke-JWADScoopInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScoopName,
        [ValidateSet('main', 'extras', 'java')][string]$Bucket = 'main'
    )

    Install-JWADScoopBootstrap

    $bucketList = Invoke-JWADScoopCommand -Arguments @('bucket', 'list')
    $bucketExists = [regex]::IsMatch($bucketList, ('(?im)^\s*{0}\s+' -f [regex]::Escape($Bucket)))
    if (-not $bucketExists) {
        $bucketArgs = @('bucket', 'add', $Bucket)
        $bucketUrl = ''
        if ($Bucket -eq 'extras') { $bucketUrl = $env:JWAD_SCOOP_EXTRAS_URL }
        if ($Bucket -eq 'main') { $bucketUrl = $env:JWAD_SCOOP_MAIN_URL }
        if ($Bucket -eq 'java') {
            $bucketUrl = $env:JWAD_SCOOP_JAVA_URL
            if ([string]::IsNullOrWhiteSpace($bucketUrl)) { $bucketUrl = 'https://github.com/ScoopInstaller/Java' }
        }
        if (-not [string]::IsNullOrWhiteSpace($bucketUrl)) {
            if (-not $bucketUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
                throw ('JWAD_SCOOP_{0}_URL debe utilizar HTTPS.' -f $Bucket.ToUpperInvariant())
            }
            $bucketArgs += $bucketUrl
        }
        [void](Invoke-JWADScoopCommand -Arguments $bucketArgs)
    }

    $package = if ($Bucket -eq 'main') { $ScoopName } else { '{0}/{1}' -f $Bucket, $ScoopName }
    [void](Invoke-JWADScoopCommand -Arguments @('install', $package))
    return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED'; ExitCode = 0; Detail = ('Scoop instalo {0}.' -f $package) }
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
        'User-Agent' = 'JWAD-Windows-App-Deployer/3.1.0'
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
                throw ('GitHub rate limit. La espera indicada ({0}s) supera el maximo configurado ({1}s).' -f $delay, $maxWait)
            }
            Start-Sleep -Seconds ([Math]::Max(1, $delay))
            $attempt++
        }
    }
    throw 'No fue posible consultar la version mas reciente en GitHub.'
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

function Get-JWADEdgeEnterpriseAsset {
    [CmdletBinding()]
    param()

    $apiUrl = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
    $requestParams = @{ Uri = $apiUrl; TimeoutSec = 60; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -eq 5) { $requestParams.UseBasicParsing = $true }
    $products = Invoke-RestMethod @requestParams
    $stable = @($products | Where-Object { [string]$_.Product -eq 'Stable' })
    if ($stable.Count -ne 1) { throw 'Microsoft Edge API did not return exactly one Stable product.' }

    $releases = @($stable[0].Releases | Where-Object {
        [string]$_.Platform -eq 'Windows' -and [string]$_.Architecture -eq 'x64'
    })
    if ($releases.Count -eq 0) { throw 'Microsoft Edge API has no Windows x64 Stable releases.' }

    $release = $releases | Sort-Object -Property { try { [version]$_.ProductVersion } catch { [version]'0.0' } } -Descending | Select-Object -First 1
    $artifacts = @($release.Artifacts | Where-Object {
        [string]$_.ArtifactName -match '(?i)^MicrosoftEdgeEnterpriseX64\.msi$' -or
        [string]$_.Location -match '(?i)/MicrosoftEdgeEnterpriseX64\.msi(?:\?|$)'
    })
    if ($artifacts.Count -ne 1) { throw ('Microsoft Edge API returned {0} matching x64 enterprise MSI artifacts.' -f $artifacts.Count) }

    $artifact = $artifacts[0]
    $hash = [string]$artifact.Hash
    if ([string]$artifact.HashAlgorithm -notmatch '(?i)^SHA-?256$' -or $hash -notmatch '^[A-Fa-f0-9]{64}$') { $hash = '' }
    return [PSCustomObject]@{
        Version = [string]$release.ProductVersion
        AssetName = 'MicrosoftEdgeEnterpriseX64.msi'
        DownloadUrl = [string]$artifact.Location
        SHA256 = $hash
    }
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
        [string]$ExpectedSigner = '',
        [string]$DirectPageUrl = '',
        [string]$DirectAssetRegex = '',
        [string]$DirectHashSuffix = '',
        [string]$DirectJsonUrl = ''
    )

    $version = 'N/A'
    $downloadUrl = ''
    $assetName = ''
    $expectedHash = $ExpectedSHA256
    $pageText = ''

    if (-not [string]::IsNullOrWhiteSpace($DirectJsonUrl)) {
        if ($DirectJsonUrl -eq 'https://edgeupdates.microsoft.com/api/products?view=enterprise') {
            $edgeAsset = Get-JWADEdgeEnterpriseAsset
            $version = $edgeAsset.Version
            $assetName = $edgeAsset.AssetName
            $downloadUrl = $edgeAsset.DownloadUrl
            if ([string]::IsNullOrWhiteSpace($expectedHash)) { $expectedHash = $edgeAsset.SHA256 }
        }
        elseif ($DirectJsonUrl -eq 'https://raw.githubusercontent.com/ScoopInstaller/Versions/master/bucket/sumatrapdf-installer.json') {
            # The manifest supplies a live version, vendor-hosted URL and SHA-256.
            # The installer itself is downloaded from SumatraPDF's official domain.
            $manifestParams = @{ Uri = $DirectJsonUrl; TimeoutSec = 45; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -eq 5) { $manifestParams.UseBasicParsing = $true }
            $sumatraManifest = Invoke-RestMethod @manifestParams
            $sumatraX64 = $sumatraManifest.architecture.'64bit'
            if ($null -eq $sumatraX64 -or [string]::IsNullOrWhiteSpace([string]$sumatraX64.url)) {
                throw 'The SumatraPDF manifest has no 64-bit installer URL.'
            }
            $downloadUrl = [string]$sumatraX64.url
            if (-not $downloadUrl.StartsWith('https://www.sumatrapdfreader.org/', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The SumatraPDF manifest points outside the official vendor download domain.'
            }
            $version = [string]$sumatraManifest.version
            $assetName = [IO.Path]::GetFileName(([Uri]$downloadUrl).AbsolutePath)
            if ([string]::IsNullOrWhiteSpace($expectedHash)) { $expectedHash = [string]$sumatraX64.hash }
            if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
                throw 'The SumatraPDF manifest does not provide a valid SHA-256 digest.'
            }
        }
        else {
            throw 'SIN INFORMACION: no existe un resolvedor JSON aprobado para DirectJsonUrl.'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Repository)) {
        if ([string]::IsNullOrWhiteSpace($AssetRegex)) {
            throw 'GitHubRepo is configured, but RegexAsset is empty. No generic asset will be selected.'
        }
        $release = Get-JWADGitHubRelease -Repository $Repository -MaxRetries $GitHubMaxRetries
        $version = [string]$release.tag_name
        $matches = @($release.assets | Where-Object { $_.name -match $AssetRegex })
        if ($matches.Count -ne 1) {
            throw ('RegexAsset matched {0} assets; exactly one is required.' -f $matches.Count)
        }
        $asset = $matches[0]
        $assetName = [string]$asset.name
        $downloadUrl = [string]$asset.browser_download_url
        if ([string]::IsNullOrWhiteSpace($expectedHash) -and [string]$asset.digest -match '^sha256:([A-Fa-f0-9]{64})$') {
            $expectedHash = $Matches[1]
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($DirectPageUrl)) {
        if ([string]::IsNullOrWhiteSpace($DirectAssetRegex)) {
            throw 'DirectPageUrl is configured, but DirectAssetRegex is empty.'
        }
        if (-not $DirectPageUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'DirectPageUrl must use HTTPS.'
        }
        $pageParams = @{ Uri = $DirectPageUrl; TimeoutSec = 60; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -eq 5) { $pageParams.UseBasicParsing = $true }
        $pageResponse = Invoke-WebRequest @pageParams
        $pageText = [string]$pageResponse.Content
        $baseUri = [Uri]$DirectPageUrl
        $candidatePageText = $pageText
        if ($AppName -eq 'WinRAR x64') {
            # Exclude beta builds and localized download tables: parse only the
            # English stable-release section published by RARLAB.
            $stableStart = $pageText.IndexOf('English WinRAR and RAR release', [StringComparison]::OrdinalIgnoreCase)
            $localizedStart = -1
            if ($stableStart -ge 0) {
                $localizedStart = $pageText.IndexOf('Localized WinRAR versions', $stableStart, [StringComparison]::OrdinalIgnoreCase)
            }
            if ($stableStart -lt 0 -or $localizedStart -le $stableStart) {
                throw 'RARLAB page layout changed: the English stable-release section could not be identified safely.'
            }
            $candidatePageText = $pageText.Substring($stableStart, $localizedStart - $stableStart)
        }
        $candidates = New-Object 'System.Collections.Generic.List[object]'
        $anchorPattern = '(?is)<a\b[^>]*?href\s*=\s*["''](?<href>[^"'']+)["''][^>]*>'
        foreach ($anchor in [regex]::Matches($candidatePageText, $anchorPattern)) {
            $href = [Net.WebUtility]::HtmlDecode([string]$anchor.Groups['href'].Value)
            if ([string]::IsNullOrWhiteSpace($href) -or $href.StartsWith('#')) { continue }
            try {
                $candidateUrl = ([Uri]::new($baseUri, $href)).AbsoluteUri
                $candidateName = [IO.Path]::GetFileName(([Uri]$candidateUrl).AbsolutePath)
                if ($candidateName -match $DirectAssetRegex) {
                    $candidates.Add([PSCustomObject]@{ Name = $candidateName; Url = $candidateUrl })
                }
            }
            catch { }
        }

        if ($candidates.Count -eq 1) {
            $assetName = $candidates[0].Name
            $downloadUrl = $candidates[0].Url
        }
        elseif ($candidates.Count -gt 1) {
            throw ('DirectAssetRegex matched {0} links on the official page; exactly one is required.' -f $candidates.Count)
        }
        else {
            # SourceForge latest/download can expose file name + SHA256 in its
            # landing page while the URL itself performs the current-file redirect.
            $nameMatch = [regex]::Match($pageText, $DirectAssetRegex, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $nameMatch.Success) {
                throw 'The official page did not expose an asset matching DirectAssetRegex.'
            }
            $assetName = [IO.Path]::GetFileName($nameMatch.Value)
            if ($AppName -eq 'Bulk Crap Uninstaller') {
                # SourceForge's latest/download page publishes the current name
                # and SHA-256. Construct the versioned file path to avoid saving
                # the HTML interstitial instead of the binary installer.
                $bcuVersionMatch = [regex]::Match($assetName, '(?i)^BCUninstaller_(?<version>\d+\.\d+\.\d+)_setup\.exe$')
                if (-not $bcuVersionMatch.Success) {
                    throw ('SourceForge returned an unrecognized BCU installer name: {0}' -f $assetName)
                }
                $bcuVersion = $bcuVersionMatch.Groups['version'].Value
                $folderVersion = [regex]::Match($bcuVersion, '^\d+\.\d+')
                $safeAssetName = [Uri]::EscapeDataString($assetName)
                $downloadUrl = 'https://downloads.sourceforge.net/project/bulk-crap-uninstaller/v{0}/{1}' -f $folderVersion.Value, $safeAssetName
                $version = $bcuVersion
            }
            else {
                $downloadUrl = $DirectPageUrl
            }
        }

        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            $pageHash = [regex]::Match($pageText, '(?is)SHA-256.{0,300}?([A-Fa-f0-9]{64})')
            if ($pageHash.Success) { $expectedHash = $pageHash.Groups[1].Value }
        }
        if ([string]::IsNullOrWhiteSpace($version)) {
            if ($AppName -eq 'WinRAR x64') {
                $winrarVersionMatch = [regex]::Match($assetName, '(?i)winrar-x64-(?<digits>\d{3,4})\.exe')
                if ($winrarVersionMatch.Success) {
                    $digits = $winrarVersionMatch.Groups['digits'].Value
                    $version = $digits.Substring(0, $digits.Length - 2) + '.' + $digits.Substring($digits.Length - 2)
                }
            }
            if ([string]::IsNullOrWhiteSpace($version)) {
                $fileVersionMatch = [regex]::Match($assetName, '(\d+(?:\.\d+)+)')
                if ($fileVersionMatch.Success) { $version = $fileVersionMatch.Groups[1].Value }
            }
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
        throw 'No GitHubRepo, DirectJsonUrl, DirectPageUrl or DirectUrl is configured.'
    }

    if (-not $downloadUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The selected download URL does not use HTTPS.'
    }

    $downloadUrl = Get-JWADDirectDownloadUrl -OriginalUrl $downloadUrl
    $extension = [IO.Path]::GetExtension($assetName).ToLowerInvariant()
    if ($extension -notin @('.exe', '.msi')) {
        throw ('Unsupported direct asset type: {0}. Only explicit EXE/MSI installers are accepted.' -f $extension)
    }

    # For VideoLAN, the official latest directory publishes a matching .sha256 file.
    if ([string]::IsNullOrWhiteSpace($expectedHash) -and -not [string]::IsNullOrWhiteSpace($DirectHashSuffix)) {
        $hashUrl = $downloadUrl + $DirectHashSuffix
        $hashParams = @{ Uri = $hashUrl; TimeoutSec = 45; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -eq 5) { $hashParams.UseBasicParsing = $true }
        $hashResponse = Invoke-WebRequest @hashParams
        $hashText = [string]$hashResponse.Content
        $hashMatch = [regex]::Match($hashText, '(?i)(?<![a-f0-9])[a-f0-9]{64}(?![a-f0-9])')
        if ($hashMatch.Success) { $expectedHash = $hashMatch.Value }
    }

    $downloadPath = Join-Path $script:TempDirectory ([Guid]::NewGuid().ToString('N') + $extension)
    try {
        $downloadParams = @{ Uri = $downloadUrl; OutFile = $downloadPath; TimeoutSec = 240; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -eq 5) { $downloadParams.UseBasicParsing = $true }
        Invoke-WebRequest @downloadParams

        if (-not (Test-Path -LiteralPath $downloadPath) -or (Get-Item -LiteralPath $downloadPath).Length -le 0) {
            throw 'The download did not produce a non-empty file.'
        }

        if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
            if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'The expected SHA-256 value has an invalid format.' }
            $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
                throw 'The downloaded SHA-256 does not match the official digest.'
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ExpectedSigner)) {
            $signature = Get-AuthenticodeSignature -FilePath $downloadPath
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike ('*{0}*' -f $ExpectedSigner)) {
                throw 'Authenticode signature is invalid or the signer does not match ExpectedSigner.'
            }
        }
        else {
            throw 'SIN INFORMACION: no trusted SHA-256 digest or expected Authenticode signer is configured. Download rejected.'
        }

        if ([string]::IsNullOrWhiteSpace($version) -or $version -eq 'N/A') {
            try {
                $fileInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($downloadPath)
                if (-not [string]::IsNullOrWhiteSpace($fileInfo.ProductVersion)) { $version = $fileInfo.ProductVersion }
                elseif (-not [string]::IsNullOrWhiteSpace($fileInfo.FileVersion)) { $version = $fileInfo.FileVersion }
            }
            catch { }
        }

        if ($extension -eq '.msi') {
            $msiArgs = '/i {0} /qn /norestart' -f (ConvertTo-JWADQuotedArgument $downloadPath)
            $proc = Invoke-JWADProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $msiArgs
        }
        else {
            if ([string]::IsNullOrWhiteSpace($Arguments)) {
                throw 'SIN INFORMACION: no verified silent arguments are configured for this EXE installer.'
            }
            $proc = Invoke-JWADProcess -FilePath $downloadPath -ArgumentList $Arguments
        }

        if ($proc.ExitCode -eq 0) {
            return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED'; ExitCode = 0; Version = $version; Detail = ('Verified direct installation: {0}' -f $assetName) }
        }
        if ($proc.ExitCode -in @(3010, 1641)) {
            return [PSCustomObject]@{ Success = $true; Status = 'INSTALLED_REBOOT_REQUIRED'; ExitCode = $proc.ExitCode; Version = $version; Detail = ('Verified direct installation; restart required: {0}' -f $assetName) }
        }
        if ($proc.ExitCode -eq 1638 -and $AppName -match '(?i)Visual C\+\+') {
            $vcRuntime = Get-JWADVCRuntimeInfo
            if ($vcRuntime) {
                return [PSCustomObject]@{ Success = $true; Status = 'ALREADY_PRESENT'; ExitCode = 1638; Version = $vcRuntime.Version; Detail = ('Microsoft installer returned ERROR_PRODUCT_VERSION; installed x64 runtime confirmed in registry: {0}.' -f $vcRuntime.Version) }
            }
            throw 'Installer returned 1638 (ERROR_PRODUCT_VERSION), but the x64 Visual C++ runtime registry key does not confirm an installed runtime.'
        }
        $installerOutput = ('{0}{1}{2}' -f [string]$proc.Output, [Environment]::NewLine, [string]$proc.Error).Trim()
        if ($installerOutput.Length -gt 2000) { $installerOutput = $installerOutput.Substring(0, 2000) }
        throw ('The direct installer returned ExitCode={0}. {1}' -f $proc.ExitCode, $installerOutput)
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
        [ValidateSet('main', 'extras', 'java')][string]$ScoopBucket = 'main',
        [string]$GitHubRepo = '',
        [string]$RegexAsset = '',
        [string]$DirectArguments = '',
        [string]$ExpectedSHA256 = '',
        [string]$DirectUrl = '',
        [string]$DirectFileName = '',
        [string]$ExpectedSigner = '',
        [string]$DetectPattern = '',
        [string]$DirectPageUrl = '',
        [string]$DirectAssetRegex = '',
        [string]$DirectHashSuffix = '',
        [string]$DirectJsonUrl = ''
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
            $r = Invoke-JWADWingetInstall -WingetId $WingetId -CustomArguments $WingetCustomArgs -DetectPattern $DetectPattern
            $attempts.Add((New-JWADAttempt -Method 'Winget' -Outcome 'SUCCESS' -Message $r.Detail -ExitCode $r.ExitCode))
            $finalStatus = $r.Status
            $finalMethod = 'Winget'
            if ($r.PSObject.Properties['Version'] -and -not [string]::IsNullOrWhiteSpace([string]$r.Version)) { $finalVersion = [string]$r.Version }
            $finalError = $null
        }
        catch {
            $message = $_.Exception.Message
            $attempts.Add((New-JWADAttempt -Method 'Winget' -Outcome 'FAILED' -Message $message))
            $finalError = $message
        }
    }
    else {
        $attempts.Add((New-JWADAttempt -Method 'Winget' -Outcome 'NOT_CONFIGURED' -Message 'SIN INFORMACION: WingetId no esta configurado.'))
    }

    # Nivel 2: Scoop solo si hay un manifiesto identificado.
    if ($finalMethod -eq 'NONE') {
        if (-not [string]::IsNullOrWhiteSpace($ScoopName)) {
            try {
                $r = Invoke-JWADScoopInstall -ScoopName $ScoopName -Bucket $ScoopBucket
                $attempts.Add((New-JWADAttempt -Method 'Scoop' -Outcome 'SUCCESS' -Message $r.Detail -ExitCode $r.ExitCode))
                $finalStatus = $r.Status
                $finalMethod = 'Scoop'
                $detectedScoop = Get-JWADInstalledApplication -DisplayNamePattern $DetectPattern
                if ($detectedScoop -and -not [string]::IsNullOrWhiteSpace($detectedScoop.DisplayVersion)) { $finalVersion = $detectedScoop.DisplayVersion }
                $finalError = $null
            }
            catch {
                $message = $_.Exception.Message
                if ($script:ScoopBootstrapAttempted -and -not $script:ScoopBootstrapSucceeded -and [string]::IsNullOrWhiteSpace($script:ScoopBootstrapFailureReason)) {
                    $script:ScoopBootstrapFailureReason = $message
                }
                $attempts.Add((New-JWADAttempt -Method 'Scoop' -Outcome 'FAILED' -Message $message))
                $finalError = $message
            }
        }
        else {
            $attempts.Add((New-JWADAttempt -Method 'Scoop' -Outcome 'NOT_CONFIGURED' -Message 'SIN INFORMACION: no se ha verificado un manifiesto Scoop para esta aplicacion.'))
        }
    }

    # Nivel 3: fuente directa, si se ha definido una ruta de confianza.
    if ($finalMethod -eq 'NONE') {
        if (-not [string]::IsNullOrWhiteSpace($GitHubRepo) -or
            -not [string]::IsNullOrWhiteSpace($DirectUrl) -or
            -not [string]::IsNullOrWhiteSpace($DirectPageUrl) -or
            -not [string]::IsNullOrWhiteSpace($DirectJsonUrl)) {
            try {
                $r = Invoke-JWADDirectInstall -AppName $AppName -Repository $GitHubRepo -AssetRegex $RegexAsset -Arguments $DirectArguments -ExpectedSHA256 $ExpectedSHA256 -DirectUrl $DirectUrl -DirectFileName $DirectFileName -ExpectedSigner $ExpectedSigner -DirectPageUrl $DirectPageUrl -DirectAssetRegex $DirectAssetRegex -DirectHashSuffix $DirectHashSuffix -DirectJsonUrl $DirectJsonUrl
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
            $attempts.Add((New-JWADAttempt -Method 'Direct' -Outcome 'NOT_CONFIGURED' -Message 'SIN INFORMACION: no existe una URL/release directa validada para esta aplicacion.'))
        }
    }

    $timer.Stop()
    if ($finalMethod -eq 'NONE') {
        $finalStatus = 'FAILED'
        $finalMethod = 'NONE'
    }
    $result = New-JWADResult -Name $AppName -Status $finalStatus -Method $finalMethod -Version $finalVersion -Seconds $timer.Elapsed.TotalSeconds -Attempts $attempts.ToArray() -ErrorMessage $finalError
    $script:InstallResults.Add($result)

    # FAILED es un estado de instalacion, no un nivel de presentacion.
    # Write-JWADMessage solo admite INFO, OK, WARN, ERROR y TITLE.
    $statusLabel = if ($finalStatus -in @('INSTALLED', 'INSTALLED_REBOOT_REQUIRED', 'INSTALLED_ALREADY_PRESENT', 'UP_TO_DATE', 'ALREADY_PRESENT')) { 'OK' } else { 'ERROR' }
    $statusMessage = '{0}: {1} mediante {2}' -f $AppName, $finalStatus, $finalMethod
    if ($finalStatus -eq 'FAILED') {
        $attemptDetails = @($attempts | ForEach-Object {
            '{0}={1}: {2}' -f $_.metodo, $_.resultado, $_.detalle
        }) -join ' || '
        if (-not [string]::IsNullOrWhiteSpace($attemptDetails)) {
            $statusMessage += ' | Intentos: ' + $attemptDetails
        }
        elseif (-not [string]::IsNullOrWhiteSpace($finalError)) {
            $statusMessage += ' | Detalle: ' + $finalError
        }
    }
    Write-JWADMessage -Level $statusLabel -Message $statusMessage
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
            # CurrentTemperature: decimas de Kelvin; 2732 equivale a 273.2 K.
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
    # En algunas imagenes LTSC/WMI restringidas, se usa el registro como respaldo.
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
    Write-JWADMessage -Level 'WARN' -Message 'Contexto no elevado. Algunos instaladores podran requerir permisos administrativos/UAC.'
}
Write-JWADMessage -Level 'INFO' -Message ('PowerShell {0}; SO {1}-bit.' -f $PSVersionTable.PSVersion, $(if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }))

# El catalogo mantiene datos por paquete. Los campos vacios son deliberados:
# no se inventan IDs, manifiestos, assets ni argumentos silenciosos.
# Firefox locale can be selected per user/device; en-US is the safe default.
$firefoxLocale = $env:JWAD_FIREFOX_LOCALE
if ([string]::IsNullOrWhiteSpace($firefoxLocale)) { $firefoxLocale = 'en-US' }
if ($firefoxLocale -notmatch '^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$') {
    Write-JWADMessage -Level 'WARN' -Message 'JWAD_FIREFOX_LOCALE has an invalid format; en-US will be used.'
    $firefoxLocale = 'en-US'
}
$firefoxDirectUrl = 'https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang={0}' -f [Uri]::EscapeDataString($firefoxLocale)
$apps = @(
    [PSCustomObject]@{
        Name = 'Visual C++ Redistributable x64'; WingetId = 'Microsoft.VCRedist.2015+.x64'; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '/install /quiet /norestart';
        ExpectedSHA256 = ''; DirectUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'; DirectFileName = 'vc_redist.x64.exe'; ExpectedSigner = 'Microsoft Corporation';
        DetectPattern = '(?i)^Microsoft Visual C\+\+ 2015-2022 Redistributable \(x64\)'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'Java Runtime Environment - Temurin 21 JRE'; WingetId = 'EclipseAdoptium.Temurin.21.JRE'; WingetCustomArgs = '';
        ScoopName = 'temurin21-jre'; ScoopBucket = 'java'; GitHubRepo = 'adoptium/temurin21-binaries'; RegexAsset = '(?i)^OpenJDK21U-jre_x64_windows_hotspot_[0-9.]+_[0-9]+\.msi$'; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = 'Eclipse Adoptium';
        DetectPattern = '(?i)^(Eclipse Temurin JRE|Eclipse Temurin 21 JRE|Temurin 21 JRE)'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = '7-Zip'; WingetId = '7zip.7zip'; WingetCustomArgs = '';
        ScoopName = '7zip'; ScoopBucket = 'main'; GitHubRepo = 'ip7z/7zip'; RegexAsset = '(?i)^7z[0-9]+-x64\.msi$'; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = '';
        DetectPattern = '(?i)^7-Zip'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'Bulk Crap Uninstaller'; WingetId = 'Klocman.BulkCrapUninstaller'; WingetCustomArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = '';
        DetectPattern = '(?i)^Bulk Crap Uninstaller'; DirectPageUrl = 'https://sourceforge.net/projects/bulk-crap-uninstaller/files/latest/download'; DirectAssetRegex = '(?i)BCUninstaller_[0-9.]+_setup\.exe'; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'SumatraPDF'; WingetId = 'SumatraPDF.SumatraPDF'; WingetCustomArgs = '';
        ScoopName = 'sumatrapdf'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '-install -silent';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = '';
        DetectPattern = '(?i)^SumatraPDF'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = 'https://raw.githubusercontent.com/ScoopInstaller/Versions/master/bucket/sumatrapdf-installer.json'
    },
    [PSCustomObject]@{
        Name = 'AB Download Manager'; WingetId = 'amir1376.ABDownloadManager'; WingetCustomArgs = '';
        ScoopName = 'abdownloadmanager'; ScoopBucket = 'extras'; GitHubRepo = 'amir1376/ab-download-manager'; RegexAsset = '(?i)^(?!.*(arm64|aarch64|arm)).*(x64|win64|amd64).*\.(exe)$'; DirectArguments = '/S';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = '';
        DetectPattern = '(?i)^AB Download Manager'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'WinRAR x64'; WingetId = 'RARLab.WinRAR'; WingetCustomArgs = '/S';
        ScoopName = 'winrar'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '/S';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = 'win.rar GmbH';
        DetectPattern = '(?i)^WinRAR'; DirectPageUrl = 'https://www.rarlab.com/download.htm'; DirectAssetRegex = '(?i)winrar-x64-[0-9]+\.exe'; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'VLC Media Player'; WingetId = 'VideoLAN.VLC'; WingetCustomArgs = '';
        ScoopName = 'vlc'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = 'VideoLAN';
        DetectPattern = '(?i)^VLC media player'; DirectPageUrl = 'https://downloads.videolan.org/videolan/vlc/last/win64/'; DirectAssetRegex = '(?i)vlc-[0-9.]+-win64\.msi'; DirectHashSuffix = '.sha256'; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'Google Chrome'; WingetId = 'Google.Chrome'; WingetCustomArgs = '';
        ScoopName = 'googlechrome'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'; DirectFileName = 'googlechromestandaloneenterprise64.msi'; ExpectedSigner = 'Google LLC';
        DetectPattern = '(?i)^Google Chrome'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'Mozilla Firefox'; WingetId = 'Mozilla.Firefox'; WingetCustomArgs = '';
        ScoopName = 'firefox'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '/S';
        ExpectedSHA256 = ''; DirectUrl = $firefoxDirectUrl; DirectFileName = 'firefox-installer.exe'; ExpectedSigner = 'Mozilla Corporation';
        DetectPattern = '(?i)^Mozilla Firefox'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'Mullvad Browser'; WingetId = 'MullvadVPN.MullvadBrowser'; WingetCustomArgs = '/S';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = 'mullvad/mullvad-browser'; RegexAsset = '(?i)^mullvad-browser-windows-x86_64-[0-9.]+\.exe$'; DirectArguments = '/S';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = 'Mullvad';
        DetectPattern = '(?i)^Mullvad Browser'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'Microsoft Edge'; WingetId = 'Microsoft.Edge'; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = 'Microsoft Corporation';
        DetectPattern = '(?i)^Microsoft Edge'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
    },
    [PSCustomObject]@{
        Name = 'FlyPhotos'; WingetId = ''; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = 'riyasy/FlyPhotos'; RegexAsset = '(?i)^(?!.*(arm64|aarch64|arm)).*(x64|win64|amd64).*\.msi$'; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = '';
        DetectPattern = '(?i)^FlyPhotos'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    }
)

# Total = 13 pasos de aplicacion y una validacion .NET.
$totalSteps = $apps.Count + 1
$step = 0

Write-Host ''
Write-JWADMessage -Level 'TITLE' -Message 'INICIO DE INSTALACIONES'
foreach ($app in $apps) {
    $step++
    Show-JWADProgress -Current $step -Total $totalSteps -Label $app.Name
    [void](Install-UniversalApp -AppName $app.Name -WingetId $app.WingetId -WingetCustomArgs $app.WingetCustomArgs -ScoopName $app.ScoopName -ScoopBucket $app.ScoopBucket -GitHubRepo $app.GitHubRepo -RegexAsset $app.RegexAsset -DirectArguments $app.DirectArguments -ExpectedSHA256 $app.ExpectedSHA256 -DirectUrl $app.DirectUrl -DirectFileName $app.DirectFileName -ExpectedSigner $app.ExpectedSigner -DetectPattern $app.DetectPattern -DirectPageUrl $app.DirectPageUrl -DirectAssetRegex $app.DirectAssetRegex -DirectHashSuffix $app.DirectHashSuffix -DirectJsonUrl $app.DirectJsonUrl)
}

$step++
Show-JWADProgress -Current $step -Total $totalSteps -Label '.NET Framework 4.8+ (validacion)'
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
    Write-JWADMessage -Level 'INFO' -Message 'Recopilando telemetria del equipo...'
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
        instalaciones_exitosas = @($script:InstallResults | Where-Object { $_.estado -like 'INSTALLED*' -or $_.estado -in @('UP_TO_DATE', 'ALREADY_PRESENT') -or $_.estado -eq 'VALIDATED' }).Count
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
        firefox_locale = $firefoxLocale
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
    elseif ($item.estado -in @('UP_TO_DATE', 'ALREADY_PRESENT', 'INSTALLED_ALREADY_PRESENT')) { $color = 'Green' }
    Write-Host ('[{0}] {1} | metodo={2} | version={3} | {4}s' -f $item.estado, $item.app_name, $item.metodo_instalacion, $item.version_instalada, $item.tiempo_instalacion_segundos) -ForegroundColor $color
}
Write-Host ''
Write-Host ('Fallos: {0} | Validaciones pendientes: {1} | Reporte: {2}' -f $failed, $validationPending, $script:ReportPath) -ForegroundColor Cyan
Write-Host ('Log: {0}' -f $script:LogPath) -ForegroundColor DarkGray
if ($failed -gt 0 -or $validationPending -gt 0) {
    Write-JWADMessage -Level 'WARN' -Message ('El proceso termino con {0} fallos de instalacion y {1} validaciones pendientes. Consulte el JSON/log.' -f $failed, $validationPending)
}
else {
    Write-JWADMessage -Level 'OK' -Message 'No se registraron fallos de instalacion ni validaciones pendientes.'
}
