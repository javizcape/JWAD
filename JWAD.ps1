#requires -Version 5.1
<#
JWAD - Windows App Deployer
Version: 3.2.5 (frontend presentation refresh; installation logic unchanged)
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
$script:JWADVersion = '3.2.5'
$script:JWADStarted = [System.Diagnostics.Stopwatch]::StartNew()
$script:JWADStartDateTime = Get-Date
$script:JWADIsAdmin = $false
$script:ScoopBootstrapAttempted = $false
$script:ScoopBootstrapSucceeded = $false
$script:ScoopBootstrapFailureReason = ''
$script:ScoopCommand = $null
$script:InstallResults = New-Object 'System.Collections.Generic.List[object]'
$script:LogDirectory = Join-Path $env:LOCALAPPDATA 'JWAD\Logs'
$script:TempDirectory = Join-Path $env:TEMP 'JWAD'
$script:PackageCacheDirectory = Join-Path $env:LOCALAPPDATA 'JWAD\Packages'
$script:GitHubReleaseCache = @{}
$script:JWAD_BCU_AlternateDownloadUrl = ''

$desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) {
    $desktop = $env:USERPROFILE
}
$script:ReportPath = Join-Path $desktop 'Reporte_Despliegue_JWAD.json'
$script:LogPath = Join-Path $script:LogDirectory ('JWAD_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

foreach ($directory in @($script:LogDirectory, $script:TempDirectory, $script:PackageCacheDirectory)) {
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
    $matchedEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $roots) {
        $entries = @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)
        foreach ($entry in $entries) {
            # Uninstall keys do not all contain DisplayName. With StrictMode,
            # reading a missing dynamic property throws and aborts detection.
            $displayNameProperty = $entry.PSObject.Properties['DisplayName']
            if ($null -eq $displayNameProperty) { continue }

            $displayName = [string]$displayNameProperty.Value
            if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName -notmatch $DisplayNamePattern) {
                continue
            }

            $versionProperty = $entry.PSObject.Properties['DisplayVersion']
            $publisherProperty = $entry.PSObject.Properties['Publisher']
            $pathProperty = $entry.PSObject.Properties['PSPath']
            $uninstallProperty = $entry.PSObject.Properties['UninstallString']
            $quietUninstallProperty = $entry.PSObject.Properties['QuietUninstallString']
            $installLocationProperty = $entry.PSObject.Properties['InstallLocation']
            $displayIconProperty = $entry.PSObject.Properties['DisplayIcon']
            $windowsInstallerProperty = $entry.PSObject.Properties['WindowsInstaller']
            $childNameProperty = $entry.PSObject.Properties['PSChildName']
            $productCode = ''
            if ($null -ne $childNameProperty -and [string]$childNameProperty.Value -match '^\{[A-Fa-f0-9-]{36}\}$') {
                $productCode = [string]$childNameProperty.Value
            }
            elseif ($null -ne $uninstallProperty) {
                $productCodeMatch = [regex]::Match([string]$uninstallProperty.Value, '\{[A-Fa-f0-9-]{36}\}')
                if ($productCodeMatch.Success) { $productCode = $productCodeMatch.Value }
            }

            [void]$matchedEntries.Add([PSCustomObject]@{
                DisplayName = $displayName
                DisplayVersion = if ($null -ne $versionProperty) { [string]$versionProperty.Value } else { '' }
                Publisher = if ($null -ne $publisherProperty) { [string]$publisherProperty.Value } else { '' }
                RegistryKey = if ($null -ne $pathProperty) { [string]$pathProperty.Value } else { '' }
                UninstallString = if ($null -ne $uninstallProperty) { [string]$uninstallProperty.Value } else { '' }
                QuietUninstallString = if ($null -ne $quietUninstallProperty) { [string]$quietUninstallProperty.Value } else { '' }
                InstallLocation = if ($null -ne $installLocationProperty) { [string]$installLocationProperty.Value } else { '' }
                DisplayIcon = if ($null -ne $displayIconProperty) { [string]$displayIconProperty.Value } else { '' }
                WindowsInstaller = if ($null -ne $windowsInstallerProperty) { [int]$windowsInstallerProperty.Value } else { 0 }
                ProductCode = $productCode
            })
        }
    }
    if ($matchedEntries.Count -eq 0) { return $null }

    # A machine can contain stale entries in both registry views and hives.
    # Return the highest parseable installed version, not the first registry hit.
    $ranked = @($matchedEntries | Sort-Object -Property @{
        Expression = {
            $comparable = ConvertTo-JWADComparableVersion ([string]$_.DisplayVersion)
            if ($null -ne $comparable) { $comparable } else { [version]'0.0' }
        }
        Descending = $true
    })
    if ($ranked.Count -gt 0) { return $ranked[0] }
    return $matchedEntries[0]
}

function ConvertTo-JWADComparableVersion {
    [CmdletBinding()]
    param([AllowNull()][string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) { return $null }
    $match = [regex]::Match($VersionText, '(?<!\d)(\d+(?:\.\d+){1,3})(?!\d)')
    if (-not $match.Success) { return $null }
    try {
        $parts = @($match.Groups[1].Value.Split('.'))
        while ($parts.Count -lt 4) { $parts += '0' }
        return [version]($parts -join '.')
    }
    catch { return $null }
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

function Get-JWADPresentationInfo {
    [CmdletBinding()]
    param()

    $info = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        Manufacturer = 'N/A'
        Model = 'N/A'
        OperatingSystem = 'Windows'
        DisplayVersion = 'N/A'
        Build = 'N/A'
        Processor = 'N/A'
        MemoryGB = 'N/A'
        Architecture = $(if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' })
        PowerShell = [string]$PSVersionTable.PSVersion
        StartDateTime = $script:JWADStartDateTime
    }

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$computer.Manufacturer)) { $info.Manufacturer = [string]$computer.Manufacturer }
        if (-not [string]::IsNullOrWhiteSpace([string]$computer.Model)) { $info.Model = [string]$computer.Model }
        if ([double]$computer.TotalPhysicalMemory -gt 0) {
            $info.MemoryGB = '{0:N2} GB' -f ([double]$computer.TotalPhysicalMemory / 1GB)
        }
    }
    catch { }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$os.Caption)) { $info.OperatingSystem = [string]$os.Caption }
        if (-not [string]::IsNullOrWhiteSpace([string]$os.BuildNumber)) { $info.Build = [string]$os.BuildNumber }
        if ($os.PSObject.Properties['OSArchitecture'] -and -not [string]::IsNullOrWhiteSpace([string]$os.OSArchitecture)) {
            $info.Architecture = [string]$os.OSArchitecture
        }
    }
    catch { }

    try {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$currentVersion.DisplayVersion)) {
            $info.DisplayVersion = [string]$currentVersion.DisplayVersion
        }
        $buildNumber = [string]$currentVersion.CurrentBuildNumber
        if ([string]::IsNullOrWhiteSpace($buildNumber)) { $buildNumber = [string]$currentVersion.CurrentBuild }
        if (-not [string]::IsNullOrWhiteSpace($buildNumber)) {
            $info.Build = $buildNumber
            if ($null -ne $currentVersion.UBR) { $info.Build = '{0}.{1}' -f $buildNumber, $currentVersion.UBR }
        }
    }
    catch { }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu -and -not [string]::IsNullOrWhiteSpace([string]$cpu.Name)) { $info.Processor = ([string]$cpu.Name).Trim() }
    }
    catch { }

    return [PSCustomObject]$info
}

function Write-JWADStartupBanner {
    [CmdletBinding()]
    param()

    $banner = @(
        '     ___        ___    ____  ',
        '    | \ \      / / \  |  _ \ ',
        ' _  | |\ \ /\ / / _ \ | | | |',
        '| |_| | \ V  V / ___ \| |_| |',
        ' \___/   \_/\_/_/   \_\____/ '
    )
    $gradient = @('Cyan', 'Blue', 'White', 'Blue', 'Cyan')

    Write-Host ''
    Write-Host '  ====================================================================' -ForegroundColor Cyan
    for ($i = 0; $i -lt $banner.Count; $i++) {
        Write-Host ('  ' + $banner[$i]) -ForegroundColor $gradient[$i]
    }
    Write-Host ('             WINDOWS APP DEPLOYER - JWAD v{0}' -f $script:JWADVersion) -ForegroundColor DarkCyan
    Write-Host '             javizcape.github.io/JWAD' -ForegroundColor DarkGray
    Write-Host '  ====================================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Write-JWADSystemInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][PSObject]$Info,
        [ValidateSet('START', 'END')][string]$Phase = 'START',
        [double]$ElapsedSeconds = 0
    )

    $now = Get-Date
    $osText = [string]$Info.OperatingSystem
    if (-not [string]::IsNullOrWhiteSpace([string]$Info.DisplayVersion) -and [string]$Info.DisplayVersion -ne 'N/A') {
        $osText += ' ' + [string]$Info.DisplayVersion
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Info.Build) -and [string]$Info.Build -ne 'N/A') {
        $osText += ' (Build ' + [string]$Info.Build + ')'
    }

    Write-Host ''
    if ($Phase -eq 'START') {
        Write-Host '  SYSTEM INFORMATION' -ForegroundColor Cyan
    }
    else {
        Write-Host '  EXECUTION SUMMARY - SYSTEM' -ForegroundColor Cyan
    }
    Write-Host ('  Date/time start : {0}' -f $Info.StartDateTime.ToString('yyyy-MM-dd HH:mm:ss zzz')) -ForegroundColor Gray
    if ($Phase -eq 'END') {
        Write-Host ('  Date/time end   : {0}' -f $now.ToString('yyyy-MM-dd HH:mm:ss zzz')) -ForegroundColor Gray
    }
    Write-Host ('  Computer        : {0}' -f (ConvertTo-JWADAsciiText -Text ([string]$Info.ComputerName))) -ForegroundColor Gray
    Write-Host ('  Manufacturer    : {0}' -f (ConvertTo-JWADAsciiText -Text ('{0} {1}' -f $Info.Manufacturer, $Info.Model))) -ForegroundColor Gray
    Write-Host ('  Operating system: {0}' -f (ConvertTo-JWADAsciiText -Text $osText)) -ForegroundColor Gray
    Write-Host ('  Architecture    : {0}' -f $Info.Architecture) -ForegroundColor Gray
    Write-Host ('  Processor       : {0}' -f (ConvertTo-JWADAsciiText -Text ([string]$Info.Processor))) -ForegroundColor Gray
    Write-Host ('  RAM             : {0}' -f $Info.MemoryGB) -ForegroundColor Gray
    Write-Host ('  PowerShell      : {0}' -f $Info.PowerShell) -ForegroundColor Gray
    Write-Host ('  JWAD version    : {0}' -f $script:JWADVersion) -ForegroundColor Gray
    if ($Phase -eq 'END') {
        Write-Host ('  Execution time  : {0:N2} seconds' -f $ElapsedSeconds) -ForegroundColor Yellow
    }
    Write-Host ''
}

function Format-JWADDisplayCell {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][ValidateRange(1, 200)][int]$Width
    )

    $text = ConvertTo-JWADAsciiText -Text ([string]$Value)
    if ($text.Length -gt $Width) {
        if ($Width -le 3) { return $text.Substring(0, $Width) }
        return ($text.Substring(0, $Width - 3) + '...')
    }
    return $text
}

function Show-JWADFinalPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        [Parameter(Mandatory = $true)][PSObject]$SystemInfo,
        [Parameter(Mandatory = $true)][int]$Failed,
        [Parameter(Mandatory = $true)][int]$ValidationPending,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][double]$ElapsedSeconds
    )

    Write-Host ''
    Write-Host '  ==================================================================================================================' -ForegroundColor Green
    Write-Host '                                      JWAD - FINAL DEPLOYMENT REPORT' -ForegroundColor Green
    Write-Host '  ==================================================================================================================' -ForegroundColor Green
    Write-JWADSystemInfo -Info $SystemInfo -Phase 'END' -ElapsedSeconds $ElapsedSeconds

    $consoleWidth = 140
    try {
        $reportedWidth = [int]$Host.UI.RawUI.WindowSize.Width
        if ($reportedWidth -ge 100) { $consoleWidth = $reportedWidth }
    }
    catch { }

    $usableWidth = [Math]::Max(108, [Math]::Min(190, $consoleWidth - 2))
    $statusWidth = 29
    $methodWidth = 16
    $timeWidth = 10
    $remaining = $usableWidth - $statusWidth - $methodWidth - $timeWidth - 12
    $appWidth = [Math]::Min(40, [Math]::Max(22, [int][Math]::Floor($remaining * 0.48)))
    $versionWidth = [Math]::Max(14, $remaining - $appWidth)
    $format = '{0,-' + $statusWidth + '} | {1,-' + $appWidth + '} | {2,-' + $methodWidth + '} | {3,-' + $versionWidth + '} | {4,' + $timeWidth + '}'

    Write-Host '  APPLICATION RESULTS' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * ($usableWidth - 4))) -ForegroundColor DarkGray
    Write-Host ('  ' + ($format -f 'STATUS', 'APPLICATION', 'METHOD', 'VERSION', 'TIME')) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * ($usableWidth - 4))) -ForegroundColor DarkGray

    foreach ($item in $Results) {
        $status = [string]$item.estado
        $application = Format-JWADDisplayCell -Value $item.app_name -Width $appWidth
        $method = Format-JWADDisplayCell -Value $item.metodo_instalacion -Width $methodWidth
        $version = Format-JWADDisplayCell -Value $item.version_instalada -Width $versionWidth
        $seconds = ([double]$item.tiempo_instalacion_segundos).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + 's'
        $statusCell = Format-JWADDisplayCell -Value ('[' + $status + ']') -Width $statusWidth
        $row = '  ' + ($format -f $statusCell, $application, $method, $version, $seconds)

        $color = 'Green'
        if ($status -eq 'FAILED') { $color = 'Red' }
        elseif ($status -in @('OUTDATED', 'UNKNOWN', 'PRESENT_UPDATE_UNKNOWN', 'STORE_MANAGED', 'NOT_SUPPORTED', 'UPDATE_BLOCKED', 'POLICY_MANAGED', 'INSTALLED_REBOOT_REQUIRED')) { $color = 'Yellow' }
        Write-Host $row -ForegroundColor $color
    }

    Write-Host ('  ' + ('-' * ($usableWidth - 4))) -ForegroundColor DarkGray
    Write-Host ('  Failures: {0} | Pending validations: {1}' -f $Failed, $ValidationPending) -ForegroundColor $(if ($Failed -gt 0) { 'Red' } elseif ($ValidationPending -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ('  Report: {0}' -f (ConvertTo-JWADAsciiText -Text $ReportPath)) -ForegroundColor Green
    Write-Host ('  Log   : {0}' -f (ConvertTo-JWADAsciiText -Text $LogPath)) -ForegroundColor DarkGray

}

function Write-JWADFooterBanner {
    [CmdletBinding()]
    param()

    $footerBanner = @(
        '    ___      ___   ___  ',
        ' _ | \ \    / /_\ |   \ ',
        '| || |\ \/\/ / _ \| |) |',
        ' \__/  \_/\_/_/ \_\___/ '
    )
    Write-Host ''
    foreach ($line in $footerBanner) { Write-Host ('  ' + $line) -ForegroundColor DarkGray }
    Write-Host '  javizcape.github.io/JWAD' -ForegroundColor DarkCyan
    Write-Host ''
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
    foreach ($line in ($output -split '[\r\n]+')) {
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
    $commands = @(Get-Command -Name 'scoop' -All -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandType -in @('Application', 'ExternalScript')
    })
    if ($commands.Count -eq 0) { return $null }
    # Prefer a native shim where available; otherwise use the installed script.
    $native = $commands | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
    if ($native) { return $native }
    return ($commands | Select-Object -First 1)
}

function Get-JWADScoopInstalledPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ScoopName)

    $safeName = [regex]::Escape($ScoopName)
    $scoopCommand = Get-JWADScoopCommand
    $policy = Get-ExecutionPolicy
    $canInvokeScoop = ($null -ne $scoopCommand) -and ($policy.ToString() -notin @('Restricted', 'AllSigned'))

    if ($canInvokeScoop) {
        try {
            $listOutput = Invoke-JWADScoopCommand -Arguments @('list')
            foreach ($line in ($listOutput -split '[\r\n]+')) {
                if ($line -match ('(?i)^\s*' + $safeName + '\s+(?<version>[^\s]+)')) {
                    return [PSCustomObject]@{
                        Installed = $true; Name = $ScoopName; Version = [string]$Matches['version']
                        Source = 'scoop list'; Root = ''; Path = ''; CommandAvailable = $true
                    }
                }
            }
        }
        catch {
            # Continue with filesystem inspection. It works when scoop.ps1 is
            # blocked by policy or its shim cannot run, without bypassing policy.
        }
    }

    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @(
        $env:SCOOP,
        $env:SCOOP_GLOBAL,
        (Join-Path $env:USERPROFILE 'scoop'),
        (Join-Path $env:LOCALAPPDATA 'Programs\scoop'),
        (Join-Path $env:ProgramData 'scoop'),
        (Join-Path $env:ProgramFiles 'Scoop'),
        (Join-Path ${env:ProgramFiles(x86)} 'Scoop')
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            $normalized = [Environment]::ExpandEnvironmentVariables([string]$candidate).TrimEnd('\')
            if (-not $roots.Contains($normalized)) { $roots.Add($normalized) }
        }
    }

    foreach ($root in $roots) {
        $appRoot = Join-Path (Join-Path $root 'apps') $ScoopName
        if (-not (Test-Path -LiteralPath $appRoot -PathType Container)) { continue }
        $currentPath = Join-Path $appRoot 'current'
        if (-not (Test-Path -LiteralPath $currentPath)) { continue }

        $version = 'N/A'
        $manifestPath = Join-Path $currentPath 'manifest.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $manifest.version) { $version = [string]$manifest.version }
            }
            catch { }
        }
        if ($version -eq 'N/A') {
            try {
                $resolved = (Resolve-Path -LiteralPath $currentPath -ErrorAction Stop).Path
                $leaf = Split-Path -Leaf $resolved
                if (-not [string]::IsNullOrWhiteSpace($leaf) -and $leaf -ne 'current') { $version = $leaf }
            }
            catch { }
        }
        return [PSCustomObject]@{
            Installed = $true; Name = $ScoopName; Version = $version
            Source = 'Scoop apps directory'; Root = $root; Path = $currentPath
            CommandAvailable = ($null -ne $scoopCommand)
        }
    }
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

function Get-JWADRemoteScoopManifestVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScoopName,
        [ValidateSet('main', 'extras', 'java')][string]$Bucket = 'main'
    )

    $repository = switch ($Bucket) {
        'main'   { 'ScoopInstaller/Main' }
        'extras' { 'ScoopInstaller/Extras' }
        'java'   { 'ScoopInstaller/Java' }
    }
    $manifestUrl = 'https://raw.githubusercontent.com/{0}/master/bucket/{1}.json' -f $repository, [Uri]::EscapeDataString($ScoopName)
    $request = @{ Uri = $manifestUrl; TimeoutSec = 45; ErrorAction = 'Stop' }
    $manifest = Invoke-RestMethod @request
    if ($null -eq $manifest.version -or [string]::IsNullOrWhiteSpace([string]$manifest.version)) {
        throw ('Official Scoop manifest {0} does not expose a version field.' -f $manifestUrl)
    }
    return [PSCustomObject]@{
        Version = [string]$manifest.version
        Url = $manifestUrl
        Repository = $repository
    }
}

function Invoke-JWADScoopInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScoopName,
        [ValidateSet('main', 'extras', 'java')][string]$Bucket = 'main'
    )

    $package = if ($Bucket -eq 'main') { $ScoopName } else { '{0}/{1}' -f $Bucket, $ScoopName }
    $existing = Get-JWADScoopInstalledPackage -ScoopName $ScoopName
    $policy = Get-ExecutionPolicy

    if ($existing -and $policy.ToString() -in @('Restricted', 'AllSigned')) {
        try {
            $remoteManifest = Get-JWADRemoteScoopManifestVersion -ScoopName $ScoopName -Bucket $Bucket
            $installedVersion = ConvertTo-JWADComparableVersion ([string]$existing.Version)
            $latestVersion = ConvertTo-JWADComparableVersion ([string]$remoteManifest.Version)
            if ($installedVersion -and $latestVersion -and $installedVersion -ge $latestVersion) {
                return [PSCustomObject]@{
                    Success = $true; Status = 'UP_TO_DATE'; ExitCode = 0
                    Version = [string]$existing.Version
                    Detail = ('Existing Scoop package {0} version {1} is equal to or newer than official manifest version {2}. Scoop execution was not needed; ExecutionPolicy={3}. Source: {4}' -f $ScoopName, $existing.Version, $remoteManifest.Version, $policy, $remoteManifest.Url)
                }
            }
            return [PSCustomObject]@{
                Success = $true; Status = 'UPDATE_BLOCKED'; ExitCode = 0
                Version = [string]$existing.Version
                Detail = ('Scoop package {0} version {1} is older than official manifest {2}, but ExecutionPolicy={3} blocks Scoop execution. No duplicate direct installer was run. Source: {4}' -f $ScoopName, $existing.Version, $remoteManifest.Version, $policy, $remoteManifest.Url)
            }
        }
        catch {
            return [PSCustomObject]@{
                Success = $true; Status = 'PRESENT_UPDATE_UNKNOWN'; ExitCode = 0
                Version = [string]$existing.Version
                Detail = ('Scoop package {0} version {1} is installed at {2}; ExecutionPolicy={3} blocks Scoop execution and the official manifest could not be queried: {4}. No duplicate direct installation was attempted.' -f $ScoopName, $existing.Version, $existing.Path, $policy, $_.Exception.Message)
            }
        }
    }

    if (-not (Get-JWADScoopCommand)) {
        Install-JWADScoopBootstrap
    }

    if ($existing) {
        try {
            $beforeVersion = [string]$existing.Version
            $updateOutput = Invoke-JWADScoopCommand -Arguments @('update', $package)
            $after = Get-JWADScoopInstalledPackage -ScoopName $ScoopName
            if (-not $after) {
                throw ('Scoop update completed but installed package {0} could not be confirmed.' -f $package)
            }
            $afterVersion = [string]$after.Version
            $beforeComparable = ConvertTo-JWADComparableVersion $beforeVersion
            $afterComparable = ConvertTo-JWADComparableVersion $afterVersion
            if ($beforeComparable -and $afterComparable -and $afterComparable -lt $beforeComparable) {
                throw ('Scoop package version regressed from {0} to {1}; no success will be reported.' -f $beforeVersion, $afterVersion)
            }
            $status = 'PRESENT_UPDATE_UNKNOWN'
            if ($beforeComparable -and $afterComparable -and $afterComparable -eq $beforeComparable) {
                $status = 'UP_TO_DATE'
            }
            elseif ($beforeComparable -and $afterComparable -and $afterComparable -gt $beforeComparable) {
                $status = 'INSTALLED'
            }
            elseif ($updateOutput -match '(?i)already up.to.date|no updates|up to date') {
                $status = 'UP_TO_DATE'
            }
            return [PSCustomObject]@{
                Success = $true; Status = $status; ExitCode = 0; Version = $afterVersion
                Detail = ('Scoop package {0}; before={1}; after={2}. {3}' -f $package, $beforeVersion, $afterVersion, $updateOutput)
            }
        }
        catch {
            # A failed Scoop update must not trigger a second distribution over
            # an existing portable copy. Query the manifest independently.
            $scoopUpdateError = $_.Exception.Message
            try {
                $remoteManifest = Get-JWADRemoteScoopManifestVersion -ScoopName $ScoopName -Bucket $Bucket
                $installedVersion = ConvertTo-JWADComparableVersion ([string]$existing.Version)
                $latestVersion = ConvertTo-JWADComparableVersion ([string]$remoteManifest.Version)
                if ($installedVersion -and $latestVersion -and $installedVersion -ge $latestVersion) {
                    return [PSCustomObject]@{
                        Success = $true; Status = 'UP_TO_DATE'; ExitCode = 0
                        Version = [string]$existing.Version
                        Detail = ('Existing Scoop package {0} version {1} is equal to or newer than official manifest version {2}; Scoop command failed ({3}). Source: {4}' -f $ScoopName, $existing.Version, $remoteManifest.Version, $scoopUpdateError, $remoteManifest.Url)
                    }
                }
                return [PSCustomObject]@{
                    Success = $true; Status = 'UPDATE_BLOCKED'; ExitCode = 0
                    Version = [string]$existing.Version
                    Detail = ('Scoop package {0} version {1}; latest official manifest {2}. Update could not run: {3}. No direct installer was run over the existing Scoop-managed copy. Source: {4}' -f $ScoopName, $existing.Version, $remoteManifest.Version, $scoopUpdateError, $remoteManifest.Url)
                }
            }
            catch {
                return [PSCustomObject]@{
                    Success = $true; Status = 'PRESENT_UPDATE_UNKNOWN'; ExitCode = 0
                    Version = [string]$existing.Version
                    Detail = ('Scoop package {0} version {1} is installed, but update verification failed: {2}; official manifest lookup also failed: {3}. No direct installer was run over the existing Scoop-managed copy.' -f $ScoopName, $existing.Version, $scoopUpdateError, $_.Exception.Message)
                }
            }
        }
    }

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
                throw ('JWAD_SCOOP_{0}_URL must use HTTPS.' -f $Bucket.ToUpperInvariant())
            }
            $bucketArgs += $bucketUrl
        }
        [void](Invoke-JWADScoopCommand -Arguments $bucketArgs)
    }

    [void](Invoke-JWADScoopCommand -Arguments @('install', $package))
    $installed = Get-JWADScoopInstalledPackage -ScoopName $ScoopName
    if (-not $installed) {
        throw ('Scoop install returned without confirming package {0} in scoop list or its app directory.' -f $package)
    }
    return [PSCustomObject]@{
        Success = $true; Status = 'INSTALLED'; ExitCode = 0
        Version = [string]$installed.Version
        Detail = ('Scoop installed {0}; version={1}.' -f $package, $installed.Version)
    }
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

    $cacheKey = $Repository.ToLowerInvariant()
    if ($script:GitHubReleaseCache.ContainsKey($cacheKey)) {
        return $script:GitHubReleaseCache[$cacheKey]
    }

    $uri = '{0}/repos/{1}/releases/latest' -f $apiBase, $Repository
    $headers = @{
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2026-03-10'
        'User-Agent' = 'JWAD-Windows-App-Deployer/3.2.2'
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
            $releaseData = $response.Content | ConvertFrom-Json -ErrorAction Stop
            $script:GitHubReleaseCache[$cacheKey] = $releaseData
            return $releaseData
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

function Get-JWADFlyPhotosInstalledState {
    [CmdletBinding()]
    param()

    $storePackages = @()
    try {
        $storePackages = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object {
            ([string]$_.Name -match '(?i)Fly\s*Photos|FlyPhotos') -or
            ([string]$_.PackageFamilyName -match '(?i)Fly\s*Photos|FlyPhotos')
        })
    }
    catch {
        try {
            $storePackages = @(Get-AppxPackage -ErrorAction Stop | Where-Object {
                ([string]$_.Name -match '(?i)Fly\s*Photos|FlyPhotos') -or
                ([string]$_.PackageFamilyName -match '(?i)Fly\s*Photos|FlyPhotos')
            })
        }
        catch { $storePackages = @() }
    }
    if ($storePackages.Count -gt 0) {
        $storePackage = $storePackages | Sort-Object { ConvertTo-JWADComparableVersion ([string]$_.Version) } -Descending | Select-Object -First 1
        return [PSCustomObject]@{
            Installed = $true
            Kind = 'Store'
            Version = [string]$storePackage.Version
            DisplayName = [string]$storePackage.Name
            InstallLocation = [string]$storePackage.InstallLocation
        }
    }

    $registry = Get-JWADInstalledApplication -DisplayNamePattern '(?i)^Fly\s*Photos(?:$|\s)|^FlyPhotos(?:$|\s)'
    if (-not $registry) {
        $knownPaths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($basePath in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if ([string]::IsNullOrWhiteSpace([string]$basePath)) { continue }
            foreach ($relativePath in @('Fly Photos\FlyPhotos.exe', 'FlyPhotos\FlyPhotos.exe', 'Programs\Fly Photos\FlyPhotos.exe', 'FlyPhotos\FlyPhotos.exe')) {
                $candidatePath = Join-Path $basePath $relativePath
                if (-not $knownPaths.Contains($candidatePath)) { $knownPaths.Add($candidatePath) }
            }
        }
        foreach ($knownPath in $knownPaths) {
            if (Test-Path -LiteralPath $knownPath) {
                $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($knownPath)
                return [PSCustomObject]@{
                    Installed = $true
                    Kind = 'MSI/EXE'
                    Version = [string]$info.ProductVersion
                    DisplayName = 'Fly Photos'
                    InstallLocation = Split-Path -Parent $knownPath
                }
            }
        }
        return $null
    }

    $version = [string]$registry.DisplayVersion
    $candidatePaths = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($registry.InstallLocation)) {
        $candidatePaths.Add((Join-Path $registry.InstallLocation 'FlyPhotos.exe'))
        $candidatePaths.Add((Join-Path $registry.InstallLocation 'Fly Photos.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($registry.DisplayIcon)) {
        $iconPath = $registry.DisplayIcon.Trim().Trim('"')
        $iconPath = [regex]::Replace($iconPath, ',\s*-?\d+\s*$', '')
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) { $candidatePaths.Add($iconPath) }
    }
    foreach ($path in ($candidatePaths | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $fileInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            if (-not [string]::IsNullOrWhiteSpace($fileInfo.ProductVersion)) { $version = [string]$fileInfo.ProductVersion; break }
            if (-not [string]::IsNullOrWhiteSpace($fileInfo.FileVersion)) { $version = [string]$fileInfo.FileVersion; break }
        }
    }
    return [PSCustomObject]@{
        Installed = $true
        Kind = 'MSI/EXE'
        Version = $version
        DisplayName = $registry.DisplayName
        InstallLocation = $registry.InstallLocation
        ProductCode = $registry.ProductCode
    }
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


function Get-JWADEdgeInstalledInfo {
    [CmdletBinding()]
    param()

    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($programFilesX86)) { $programFilesX86 = Join-Path $env:SystemDrive 'Program Files (x86)' }
    $candidatePaths = @(
        (Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    $appPathKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )
    foreach ($keyPath in $appPathKeys) {
        try {
            $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
            $value = [string]$key.GetValue('')
            if (-not [string]::IsNullOrWhiteSpace($value)) { $candidatePaths += $value }
        }
        catch { }
    }

    $registryVersion = ''
    $versionKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Edge\BLBeacon',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\BLBeacon',
        'HKCU:\SOFTWARE\Microsoft\Edge\BLBeacon',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
    )
    foreach ($keyPath in $versionKeys) {
        try {
            $key = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
            foreach ($propertyName in @('version', 'pv', 'ProductVersion')) {
                $property = $key.PSObject.Properties[$propertyName]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $registryVersion = [string]$property.Value
                    break
                }
            }
            if ($registryVersion) { break }
        }
        catch { }
    }

    foreach ($path in ($candidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $fileInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            $version = [string]$fileInfo.ProductVersion
            if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$fileInfo.FileVersion }
            if ([string]::IsNullOrWhiteSpace($version)) { $version = $registryVersion }
            if ([string]::IsNullOrWhiteSpace($version)) { $version = 'UNKNOWN' }
            return [PSCustomObject]@{ Installed = $true; Version = $version; Executable = $path }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($registryVersion)) {
        return [PSCustomObject]@{ Installed = $true; Version = $registryVersion; Executable = '' }
    }
    return $null
}

function Get-JWADEdgeUpdateExecutable {
    [CmdletBinding()]
    param()

    $programFilesX86 = ${env:ProgramFiles(x86)}
    $paths = @(
        (Join-Path $programFilesX86 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe')
    )
    foreach ($path in $paths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    return $null
}

function Invoke-JWADEdgeUpdate {
    [CmdletBinding()]
    param()

    $installed = Get-JWADEdgeInstalledInfo
    if (-not $installed) { return $null }

    try {
        $latest = Get-JWADEdgeEnterpriseAsset
    }
    catch {
        return [PSCustomObject]@{
            Success = $true; Status = 'PRESENT_UPDATE_UNKNOWN'; ExitCode = 0; Version = $installed.Version
            Detail = ('Existing Microsoft Edge {0} detected, but Microsoft Edge Update API could not be queried: {1}' -f $installed.Version, $_.Exception.Message)
        }
    }
    $currentVersion = ConvertTo-JWADComparableVersion $installed.Version
    $latestVersion = ConvertTo-JWADComparableVersion $latest.Version
    if ($null -eq $latestVersion) { throw ('Microsoft Edge API returned an invalid version: {0}' -f $latest.Version) }
    if ($currentVersion -and $currentVersion -ge $latestVersion) {
        return [PSCustomObject]@{
            Success = $true; Status = 'UP_TO_DATE'; ExitCode = 0; Version = $installed.Version
            Detail = ('Existing Microsoft Edge {0} is equal to or newer than the current Stable x64 release {1}.' -f $installed.Version, $latest.Version)
        }
    }

    # Do not override enterprise channel/version/update policies. The Microsoft
    # command below performs a manual update and does not honor target overrides.
    $policyPaths = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate',
        'HKLM:\SOFTWARE\WOW6432Node\Policies\Microsoft\EdgeUpdate',
        'HKCU:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    )
    $stableGuid = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
    foreach ($policyPath in $policyPaths) {
        $policy = Get-ItemProperty -LiteralPath $policyPath -ErrorAction SilentlyContinue
        if (-not $policy) { continue }
        $targetProperty = $policy.PSObject.Properties['TargetVersionPrefix' + $stableGuid]
        if ($null -ne $targetProperty -and -not [string]::IsNullOrWhiteSpace([string]$targetProperty.Value)) {
            return [PSCustomObject]@{
                Success = $true; Status = 'POLICY_MANAGED'; ExitCode = 0; Version = $installed.Version
                Detail = ('Existing Edge {0} is governed by TargetVersionPrefix={1} in {2}; JWAD will not override the policy.' -f $installed.Version, $targetProperty.Value, $policyPath)
            }
        }
        $channelProperty = $policy.PSObject.Properties['TargetChannel' + $stableGuid]
        if ($null -ne $channelProperty -and -not [string]::IsNullOrWhiteSpace([string]$channelProperty.Value) -and [string]$channelProperty.Value -notmatch '^(?i:stable)$') {
            return [PSCustomObject]@{
                Success = $true; Status = 'POLICY_MANAGED'; ExitCode = 0; Version = $installed.Version
                Detail = ('Existing Edge {0} follows TargetChannel={1} in {2}; JWAD will not switch update channels.' -f $installed.Version, $channelProperty.Value, $policyPath)
            }
        }
        $updateProperty = $policy.PSObject.Properties['Update' + $stableGuid]
        if ($null -eq $updateProperty) { $updateProperty = $policy.PSObject.Properties['UpdateDefault'] }
        if ($null -ne $updateProperty) {
            $updateValue = -1
            if ([int]::TryParse([string]$updateProperty.Value, [ref]$updateValue) -and $updateValue -in @(0, 3)) {
                return [PSCustomObject]@{
                    Success = $true; Status = 'POLICY_MANAGED'; ExitCode = 0; Version = $installed.Version
                    Detail = ('Existing Edge {0} is governed by Update policy value {1} in {2} (updates disabled or automatic-silent-only); JWAD will not override it.' -f $installed.Version, $updateValue, $policyPath)
                }
            }
        }
    }

    $updater = Get-JWADEdgeUpdateExecutable
    if (-not $updater) {
        return [PSCustomObject]@{
            Success = $true; Status = 'UPDATE_BLOCKED'; ExitCode = 0; Version = $installed.Version
            Detail = ('Microsoft Edge {0} is older than current Stable x64 {1}, but MicrosoftEdgeUpdate.exe was not found. JWAD will not repeat the enterprise MSI path that failed with MSI 1722.' -f $installed.Version, $latest.Version)
        }
    }

    $appGuid = '56EB18F8-B008-4CBD-B6D2-8C97FE7E9062'
    $arguments = '/silent /install appguid={' + $appGuid + '}&appname=Microsoft%20Edge&needsadmin=True'
    $processResult = Invoke-JWADProcess -FilePath $updater -ArgumentList $arguments -TimeoutSeconds 900
    if ($processResult.ExitCode -notin @(0, 3010, 1641)) {
        throw ('Microsoft Edge Update returned ExitCode={0}. {1}' -f $processResult.ExitCode, $processResult.Error)
    }

    $edgeWaitSeconds = 300
    $edgeWaitOverride = 0
    if ([int]::TryParse([string]$env:JWAD_EDGE_UPDATE_WAIT_SECONDS, [ref]$edgeWaitOverride) -and $edgeWaitOverride -ge 60 -and $edgeWaitOverride -le 900) {
        $edgeWaitSeconds = $edgeWaitOverride
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($edgeWaitSeconds)
    $after = $null
    do {
        Start-Sleep -Seconds 3
        $after = Get-JWADEdgeInstalledInfo
        $afterVersion = if ($after) { ConvertTo-JWADComparableVersion $after.Version } else { $null }
        if ($afterVersion -and $afterVersion -ge $latestVersion) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $after) { throw 'Microsoft Edge Update ended, but msedge.exe could not be detected afterward.' }
    $afterVersion = ConvertTo-JWADComparableVersion $after.Version
    if ($afterVersion -and $afterVersion -ge $latestVersion) {
        return [PSCustomObject]@{
            Success = $true
            Status = if ($processResult.ExitCode -in @(3010, 1641)) { 'INSTALLED_REBOOT_REQUIRED' } else { 'INSTALLED' }
            ExitCode = $processResult.ExitCode
            Version = $after.Version
            Detail = ('Microsoft Edge updated through the official Microsoft Edge Update client: {0} -> {1}.' -f $installed.Version, $after.Version)
        }
    }
    throw ('Microsoft Edge Update completed (ExitCode={0}), but the installed version remained {1}; target Stable x64 version is {2}.' -f $processResult.ExitCode, $after.Version, $latest.Version)
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
    if ($AppName -eq 'Bulk Crap Uninstaller') { $script:JWAD_BCU_AlternateDownloadUrl = '' }

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
        if ($AppName -eq 'Bulk Crap Uninstaller') {
            # SourceForge latest/download page is the canonical dynamic endpoint.
            # It publishes the current exact filename and matching SHA-256 together.
            $bcuNameMatch = [regex]::Match($pageText, '(?i)BCUninstaller_(?<version>\d+(?:\.\d+){1,3})_setup\.exe')
            if (-not $bcuNameMatch.Success) {
                throw 'SourceForge latest/download did not expose a current BCUninstaller setup filename.'
            }
            $assetName = $bcuNameMatch.Value
            $version = $bcuNameMatch.Groups['version'].Value
            $assetHashPattern = '(?is)' + [regex]::Escape($assetName) + '.{0,2500}?SHA-256.{0,1000}?(?<hash>[A-Fa-f0-9]{64})'
            $bcuHashMatch = [regex]::Match($pageText, $assetHashPattern)
            if (-not $bcuHashMatch.Success) {
                $allHashes = [regex]::Matches($pageText, '(?is)SHA-256.{0,1000}?([A-Fa-f0-9]{64})')
                if ($allHashes.Count -eq 1) { $expectedHash = $allHashes[0].Groups[1].Value.ToUpperInvariant() }
                else { throw ('SourceForge latest/download did not expose one unambiguous SHA-256 digest for {0}.' -f $assetName) }
            }
            else { $expectedHash = $bcuHashMatch.Groups['hash'].Value.ToUpperInvariant() }
            $versionParts = @($version.Split('.'))
            if ($versionParts.Count -lt 2) { throw ('SourceForge returned an invalid BCU version: {0}' -f $version) }
            $folderVersion = 'v{0}.{1}' -f $versionParts[0], $versionParts[1]
            # Start with SourceForge's dynamic latest/download redirect. A
            # versioned canonical path is added as a second verified candidate.
            $downloadUrl = $DirectPageUrl
            $script:JWAD_BCU_AlternateDownloadUrl = 'https://downloads.sourceforge.net/project/bulk-crap-uninstaller/{0}/{1}' -f $folderVersion, [Uri]::EscapeDataString($assetName)
        }
        else {
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

                if ([string]::IsNullOrWhiteSpace($expectedHash)) {
                    # SourceForge publishes the digest on the file-specific
                    # metadata page. Tie the digest to this exact asset name.
                    $bcuMetadataUrl = 'https://sourceforge.net/projects/bulk-crap-uninstaller/files/v{0}/{1}/download' -f $folderVersion.Value, $safeAssetName
                    $bcuMetadataParams = @{ Uri = $bcuMetadataUrl; TimeoutSec = 60; ErrorAction = 'Stop' }
                    if ($PSVersionTable.PSVersion.Major -eq 5) { $bcuMetadataParams.UseBasicParsing = $true }
                    $bcuMetadataResponse = Invoke-WebRequest @bcuMetadataParams
                    $bcuMetadataText = [string]$bcuMetadataResponse.Content
                    $bcuHashPattern = '(?is)' + [regex]::Escape($assetName) + '.{0,1500}?SHA-256.{0,150}?([A-Fa-f0-9]{64})'
                    $bcuHashMatch = [regex]::Match($bcuMetadataText, $bcuHashPattern)
                    if (-not $bcuHashMatch.Success) {
                        throw ('SourceForge did not publish a SHA-256 tied to the exact asset {0}.' -f $assetName)
                    }
                    $expectedHash = $bcuHashMatch.Groups[1].Value
                }
            }
            else {
                $downloadUrl = $DirectPageUrl
            }
        }

        if ([string]::IsNullOrWhiteSpace($expectedHash) -and $AppName -ne 'Bulk Crap Uninstaller') {
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
    $downloadCandidates = New-Object 'System.Collections.Generic.List[string]'
    $downloadCandidates.Add($downloadUrl)
    if ($AppName -eq 'Bulk Crap Uninstaller' -and -not [string]::IsNullOrWhiteSpace($script:JWAD_BCU_AlternateDownloadUrl)) {
        if (-not $downloadCandidates.Contains($script:JWAD_BCU_AlternateDownloadUrl)) { $downloadCandidates.Add($script:JWAD_BCU_AlternateDownloadUrl) }
        $script:JWAD_BCU_AlternateDownloadUrl = ''
    }
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

    $retainDownload = ($AppName -eq 'FlyPhotos' -and $extension -eq '.msi')
    if ($retainDownload) {
        $safeAppFolder = [regex]::Replace($AppName, '[^A-Za-z0-9_-]', '_')
        $safeVersionFolder = [regex]::Replace($version, '[^A-Za-z0-9_.-]', '_')
        if ([string]::IsNullOrWhiteSpace($safeVersionFolder)) { $safeVersionFolder = 'latest' }
        $packageFolder = Join-Path $script:PackageCacheDirectory (Join-Path $safeAppFolder $safeVersionFolder)
        if (-not (Test-Path -LiteralPath $packageFolder)) { New-Item -ItemType Directory -Path $packageFolder -Force | Out-Null }
        $downloadPath = Join-Path $packageFolder ([IO.Path]::GetFileName($assetName))
    }
    else {
        $downloadPath = Join-Path $script:TempDirectory ([Guid]::NewGuid().ToString('N') + $extension)
    }
    $keepCachedFile = $false
    try {
        $downloadTimeoutSeconds = 240
        if ($AppName -eq 'Google Chrome') { $downloadTimeoutSeconds = 900 }
        $timeoutOverride = 0
        if ([int]::TryParse([string]$env:JWAD_DOWNLOAD_TIMEOUT_SECONDS, [ref]$timeoutOverride) -and $timeoutOverride -ge 60 -and $timeoutOverride -le 3600) {
            $downloadTimeoutSeconds = $timeoutOverride
        }

        $cachedFileValid = $false
        if ($retainDownload -and (Test-Path -LiteralPath $downloadPath -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace($expectedHash)) {
            $cachedHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
            if ($cachedHash -eq $expectedHash.ToUpperInvariant()) { $cachedFileValid = $true }
            else { Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue }
        }

        if (-not $cachedFileValid) {
            $downloadedAndVerified = $false
            $candidateErrors = New-Object 'System.Collections.Generic.List[string]'
            foreach ($candidateUrl in $downloadCandidates) {
                if (-not $candidateUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
                    $candidateErrors.Add(('Rejected non-HTTPS URL: {0}' -f $candidateUrl))
                    continue
                }
                if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue }
                try {
                    $downloadParams = @{ Uri = $candidateUrl; OutFile = $downloadPath; TimeoutSec = $downloadTimeoutSeconds; ErrorAction = 'Stop' }
                    if ($PSVersionTable.PSVersion.Major -eq 5) { $downloadParams.UseBasicParsing = $true }
                    $previousProgressPreference = $ProgressPreference
                    try {
                        $ProgressPreference = 'SilentlyContinue'
                        Invoke-WebRequest @downloadParams
                    }
                    finally { $ProgressPreference = $previousProgressPreference }

                    if (-not (Test-Path -LiteralPath $downloadPath) -or (Get-Item -LiteralPath $downloadPath).Length -le 0) {
                        throw 'The download did not produce a non-empty file.'
                    }
                    if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$' -and [string]::IsNullOrWhiteSpace($ExpectedSigner)) {
                        throw 'SIN INFORMACION: no trusted SHA-256 digest or expected Authenticode signer is configured. Download rejected.'
                    }
                    if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
                        $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
                        if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
                            throw ('SHA-256 mismatch. Expected={0}; actual={1}.' -f $expectedHash.ToUpperInvariant(), $actualHash)
                        }
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($ExpectedSigner)) {
                        $signature = Get-AuthenticodeSignature -FilePath $downloadPath
                        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike ('*{0}*' -f $ExpectedSigner)) {
                            throw 'Authenticode signature is invalid or the signer does not match ExpectedSigner.'
                        }
                    }
                    $downloadedAndVerified = $true
                    break
                }
                catch {
                    $candidateErrors.Add(('{0}: {1}' -f $candidateUrl, $_.Exception.Message))
                    if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue }
                }
            }
            if (-not $downloadedAndVerified) {
                throw ('No official download candidate passed integrity validation. {0}' -f (($candidateErrors.ToArray()) -join ' || '))
            }
        }
        else {
            # Cached MSI has already passed the expected SHA-256 check above.
        }

        # Reject an HTML/interstitial response saved with an installer extension.
        $fileStream = [IO.File]::OpenRead($downloadPath)
        try {
            $signatureBytes = New-Object byte[] 8
            $bytesRead = $fileStream.Read($signatureBytes, 0, 8)
        }
        finally { $fileStream.Dispose() }
        if ($extension -eq '.exe') {
            if ($bytesRead -lt 2 -or $signatureBytes[0] -ne 0x4D -or $signatureBytes[1] -ne 0x5A) {
                throw ('Downloaded file {0} does not have a valid PE MZ header; it may be an HTML/interstitial response.' -f $assetName)
            }
        }
        elseif ($extension -eq '.msi') {
            $oleHeader = [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1)
            $headerValid = ($bytesRead -ge 8)
            for ($headerIndex = 0; $headerIndex -lt 8 -and $headerValid; $headerIndex++) {
                if ($signatureBytes[$headerIndex] -ne $oleHeader[$headerIndex]) { $headerValid = $false }
            }
            if (-not $headerValid) {
                throw ('Downloaded file {0} does not have the expected Windows Installer OLE header.' -f $assetName)
            }
        }

        if ($retainDownload) { $keepCachedFile = $true }

        if ([string]::IsNullOrWhiteSpace($version) -or $version -eq 'N/A') {
            try {
                $fileInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($downloadPath)
                if (-not [string]::IsNullOrWhiteSpace($fileInfo.ProductVersion)) { $version = $fileInfo.ProductVersion }
                elseif (-not [string]::IsNullOrWhiteSpace($fileInfo.FileVersion)) { $version = $fileInfo.FileVersion }
            }
            catch { }
        }

        $targetReleaseVersion = [string]$version
        $msiLogPath = ''
        if ($extension -eq '.msi') {
            $safeAppLogName = [regex]::Replace($AppName, '[^A-Za-z0-9_-]', '_')
            $msiLogPath = Join-Path $script:LogDirectory ('MSI_{0}_{1}.log' -f $safeAppLogName, (Get-Date -Format 'yyyyMMdd_HHmmssfff'))
            $msiArgs = '/i {0} /qn /norestart /L*v {1}' -f (ConvertTo-JWADQuotedArgument $downloadPath), (ConvertTo-JWADQuotedArgument $msiLogPath)

            # Google documents NOGOOGLEUPDATEPING=1 for firewall-restricted
            # Chrome MSI deployments where Google Update checks delay setup.
            if ($AppName -eq 'Google Chrome') { $msiArgs += ' NOGOOGLEUPDATEPING=1' }

            $proc = Invoke-JWADProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $msiArgs
        }
        else {
            if ([string]::IsNullOrWhiteSpace($Arguments)) {
                throw 'SIN INFORMACION: no verified silent arguments are configured for this EXE installer.'
            }
            $proc = Invoke-JWADProcess -FilePath $downloadPath -ArgumentList $Arguments
        }

        if ($AppName -eq 'FlyPhotos' -and $proc.ExitCode -in @(0, 3010, 1641)) {
            $flyInstalled = $null
            $verifyDeadline = [DateTime]::UtcNow.AddSeconds(45)
            do {
                Start-Sleep -Seconds 3
                $flyInstalled = Get-JWADFlyPhotosInstalledState
                if ($flyInstalled) { break }
            } while ([DateTime]::UtcNow -lt $verifyDeadline)
            if (-not $flyInstalled) {
                throw ('FlyPhotos MSI returned ExitCode={0}, but the application was not found in AppX, Uninstall registry entries, or known executable locations. MSI log: {1}' -f $proc.ExitCode, $msiLogPath)
            }
            $installedComparable = ConvertTo-JWADComparableVersion ([string]$flyInstalled.Version)
            $releaseComparable = ConvertTo-JWADComparableVersion $targetReleaseVersion
            if ($installedComparable -and $releaseComparable -and $installedComparable -lt $releaseComparable) {
                throw ('FlyPhotos installer returned ExitCode={0}, but detected installed version {1}, below release {2}. MSI log: {3}' -f $proc.ExitCode, $flyInstalled.Version, $targetReleaseVersion, $msiLogPath)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$flyInstalled.Version)) {
                $version = [string]$flyInstalled.Version
            }
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
        if (-not [string]::IsNullOrWhiteSpace($msiLogPath) -and (Test-Path -LiteralPath $msiLogPath)) {
            $failureContext = @(
                Select-String -LiteralPath $msiLogPath -Pattern 'Return value 3' -Context 8, 2 -ErrorAction SilentlyContinue |
                    Select-Object -Last 2
            )
            if ($failureContext.Count -gt 0) {
                $contextText = ($failureContext | ForEach-Object {
                    (@($_.Context.PreContext) + @($_.Line) + @($_.Context.PostContext)) -join ' '
                }) -join ' | '
                $installerOutput = ('{0} MSI failure context: {1}' -f $installerOutput, $contextText).Trim()
            }
            $installerOutput = ('{0} MSI log: {1}' -f $installerOutput, $msiLogPath).Trim()
        }
        if ($installerOutput.Length -gt 4000) { $installerOutput = $installerOutput.Substring(0, 4000) }
        if ($AppName -eq 'FlyPhotos' -and $installerOutput -match '(?i)SECREPAIR|SECUREREPAIR|1316') {
            throw ('FlyPhotos MSI source verification failed (1316/SECREPAIR). The verified MSI was retained at {0}. Check Windows Installer source-cache integrity, access to the retained MSI, and residual installer registration; no automatic registry cleanup was attempted. {1}' -f $downloadPath, $installerOutput)
        }
        throw ('The direct installer returned ExitCode={0}. {1}' -f $proc.ExitCode, $installerOutput)
    }
    finally {
        if ((-not $keepCachedFile) -and (Test-Path -LiteralPath $downloadPath)) {
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

    # FlyPhotos has no verified Winget/Scoop manifest in this catalog. Compare
    # its installed version with the current stable GitHub release before MSI.
    if ($AppName -eq 'FlyPhotos') {
        $osBuild = [Environment]::OSVersion.Version.Build
        if ($osBuild -lt 17763) {
            $attempts.Add((New-JWADAttempt -Method 'Compatibility' -Outcome 'NOT_SUPPORTED' -Message ('FlyPhotos requires Windows 10 build 17763 or later; detected build {0}.' -f $osBuild)))
            $finalStatus = 'NOT_SUPPORTED'
            $finalMethod = 'Compatibility'
        }
        else {
            $flyInstalled = Get-JWADFlyPhotosInstalledState
            if ($flyInstalled) {
                try {
                    $latestFlyRelease = Get-JWADGitHubRelease -Repository 'riyasy/FlyPhotos' -MaxRetries $GitHubMaxRetries
                    $latestFlyVersion = ConvertTo-JWADComparableVersion ([string]$latestFlyRelease.tag_name)
                    $installedFlyVersion = ConvertTo-JWADComparableVersion ([string]$flyInstalled.Version)
                    if ($null -eq $latestFlyVersion) { throw ('FlyPhotos latest release tag is not a parseable version: {0}' -f $latestFlyRelease.tag_name) }
                    if ($flyInstalled.Kind -eq 'Store') {
                        if ($installedFlyVersion -and $installedFlyVersion -ge $latestFlyVersion) {
                            $attempts.Add((New-JWADAttempt -Method 'Detection' -Outcome 'SUCCESS' -Message ('FlyPhotos Store {0} is equal to or newer than latest stable GitHub MSI release {1}; Store package is not replaced.' -f $flyInstalled.Version, $latestFlyRelease.tag_name)))
                            $finalStatus = 'UP_TO_DATE'
                        }
                        else {
                            $attempts.Add((New-JWADAttempt -Method 'Detection' -Outcome 'STORE_MANAGED' -Message ('The Microsoft Store edition is installed at {0}; JWAD will not replace it with the distinct GitHub MSI edition. Version comparison is not conclusive or Store release differs; updates remain Store-managed.' -f $flyInstalled.Version)))
                            $finalStatus = 'STORE_MANAGED'
                        }
                        $finalMethod = 'Store'
                        $finalVersion = [string]$flyInstalled.Version
                    }
                    elseif ($null -eq $installedFlyVersion) {
                        $attempts.Add((New-JWADAttempt -Method 'Detection' -Outcome 'VERSION_UNKNOWN' -Message 'FlyPhotos is present but its installed version could not be read. To avoid reinstalling over an existing MSI, JWAD will preserve it and report the update state as unknown.'))
                        $finalStatus = 'PRESENT_UPDATE_UNKNOWN'
                        $finalMethod = 'Detection'
                        $finalVersion = [string]$flyInstalled.Version
                    }
                    elseif ($installedFlyVersion -ge $latestFlyVersion) {
                        $attempts.Add((New-JWADAttempt -Method 'Detection' -Outcome 'SUCCESS' -Message ('FlyPhotos {0} is equal to or newer than latest stable release {1}.' -f $flyInstalled.Version, $latestFlyRelease.tag_name)))
                        $finalStatus = 'UP_TO_DATE'
                        $finalMethod = 'Detection'
                        $finalVersion = [string]$flyInstalled.Version
                    }
                    else {
                        $attempts.Add((New-JWADAttempt -Method 'Detection' -Outcome 'UPDATE_REQUIRED' -Message ('Installed FlyPhotos {0}; latest stable release is {1}. The WiX-based MSI from v2.6.0+ supports in-place upgrade.' -f $flyInstalled.Version, $latestFlyRelease.tag_name)))
                    }
                }
                catch {
                    $attempts.Add((New-JWADAttempt -Method 'Detection' -Outcome 'UPDATE_CHECK_FAILED' -Message $_.Exception.Message))
                    $finalStatus = 'PRESENT_UPDATE_UNKNOWN'
                    $finalMethod = 'Detection'
                    $finalVersion = [string]$flyInstalled.Version
                    $finalError = $_.Exception.Message
                }
            }
            else {
                $attempts.Add((New-JWADAttempt -Method 'Detection' -Outcome 'NOT_INSTALLED' -Message 'No FlyPhotos Store package, uninstall registry entry, or known executable was detected.'))
            }
        }
    }

    # Nivel 1: Winget
    if (-not [string]::IsNullOrWhiteSpace($WingetId)) {
        try {
            $r = Invoke-JWADWingetInstall -WingetId $WingetId -CustomArguments $WingetCustomArgs -DetectPattern $DetectPattern
            $effectiveMethod = 'Winget'
            $attempts.Add((New-JWADAttempt -Method 'Winget' -Outcome 'SUCCESS' -Message $r.Detail -ExitCode $r.ExitCode))

            # WinGet can report no applicable package update while its source
            # metadata is older than the vendor's current Edge Stable release.
            # For an existing Edge already classified as current by WinGet,
            # independently verify against Microsoft's live x64 Stable API and
            # invoke the documented Edge Update client only when needed.
            if ($AppName -eq 'Microsoft Edge' -and $r.Status -in @('UP_TO_DATE', 'ALREADY_PRESENT')) {
                $edgeInstalledBeforeCheck = Get-JWADEdgeInstalledInfo
                if ($edgeInstalledBeforeCheck) {
                    $edgeValidation = Invoke-JWADEdgeUpdate
                    if ($null -ne $edgeValidation) {
                        $attempts.Add((New-JWADAttempt -Method 'EdgeUpdate' -Outcome ([string]$edgeValidation.Status) -Message ([string]$edgeValidation.Detail) -ExitCode $edgeValidation.ExitCode))
                        $r = $edgeValidation
                        if ($edgeValidation.Status -ne 'UP_TO_DATE') { $effectiveMethod = 'EdgeUpdate' }
                    }
                }
            }

            $finalStatus = $r.Status
            $finalMethod = $effectiveMethod
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
                $scoopOutcome = if ($r.Status -eq 'PRESENT_UPDATE_UNKNOWN') { 'UPDATE_UNKNOWN' } else { [string]$r.Status }
                $attempts.Add((New-JWADAttempt -Method 'Scoop' -Outcome $scoopOutcome -Message $r.Detail -ExitCode $r.ExitCode))
                $finalStatus = $r.Status
                $finalMethod = 'Scoop'
                # Scoop reports the package version even for portable installs
                # that do not create a Windows Uninstall registry entry.
                if ($r.PSObject.Properties['Version'] -and -not [string]::IsNullOrWhiteSpace([string]$r.Version)) {
                    $finalVersion = [string]$r.Version
                }
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
                if ($AppName -eq 'Microsoft Edge' -and (Get-JWADEdgeInstalledInfo)) {
                    $r = Invoke-JWADEdgeUpdate
                    $directMethodName = 'EdgeUpdate'
                }
                else {
                    $r = Invoke-JWADDirectInstall -AppName $AppName -Repository $GitHubRepo -AssetRegex $RegexAsset -Arguments $DirectArguments -ExpectedSHA256 $ExpectedSHA256 -DirectUrl $DirectUrl -DirectFileName $DirectFileName -ExpectedSigner $ExpectedSigner -DirectPageUrl $DirectPageUrl -DirectAssetRegex $DirectAssetRegex -DirectHashSuffix $DirectHashSuffix -DirectJsonUrl $DirectJsonUrl
                    $directMethodName = 'Direct'
                }
                $attempts.Add((New-JWADAttempt -Method $directMethodName -Outcome 'SUCCESS' -Message $r.Detail -ExitCode $r.ExitCode))
                $finalStatus = $r.Status
                $finalMethod = $directMethodName
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
    $statusLabel = if ($finalStatus -in @('INSTALLED', 'INSTALLED_REBOOT_REQUIRED', 'INSTALLED_ALREADY_PRESENT', 'UP_TO_DATE', 'ALREADY_PRESENT')) { 'OK' } elseif ($finalStatus -in @('PRESENT_UPDATE_UNKNOWN', 'STORE_MANAGED', 'NOT_SUPPORTED', 'UPDATE_BLOCKED', 'POLICY_MANAGED')) { 'WARN' } else { 'ERROR' }
    $statusMessage = '{0}: {1} mediante {2}' -f $AppName, $finalStatus, $finalMethod
    if ($finalStatus -in @('FAILED', 'PRESENT_UPDATE_UNKNOWN', 'UPDATE_BLOCKED', 'POLICY_MANAGED', 'STORE_MANAGED', 'NOT_SUPPORTED')) {
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
# INSTALACION REAL DE .NET FRAMEWORK RUNTIME (VERSION MAS ALTA COMPATIBLE)
# -----------------------------------------------------------------------------
function Get-JWADDotNetFrameworkRelease {
    [CmdletBinding()]
    param()

    $baseKey = $null
    $releaseKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $releaseKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full')
        if ($null -eq $releaseKey) { return 0 }
        $value = $releaseKey.GetValue('Release', 0)
        return [int]$value
    }
    finally {
        if ($null -ne $releaseKey) { $releaseKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Get-JWADDotNetReleaseName {
    [CmdletBinding()]
    param([int]$Release)

    if ($Release -ge 533320) { return '4.8.1' }
    if ($Release -ge 528040) { return '4.8' }
    if ($Release -ge 461808) { return '4.7.2' }
    if ($Release -ge 461308) { return '4.7.1' }
    if ($Release -ge 460798) { return '4.7' }
    if ($Release -ge 394802) { return '4.6.2' }
    if ($Release -ge 394254) { return '4.6.1' }
    if ($Release -ge 393295) { return '4.6' }
    if ($Release -ge 379893) { return '4.5.2' }
    if ($Release -ge 378675) { return '4.5.1' }
    if ($Release -ge 378389) { return '4.5' }
    if ($Release -gt 0) { return 'anterior a 4.5' }
    return 'no detectado'
}

function Get-JWADDotNetTarget {
    [CmdletBinding()]
    param()

    $baseKey = $null
    $osKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $osKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
        if ($null -eq $osKey) { throw 'No se pudo leer la version de Windows desde el registro.' }

        $buildValue = $osKey.GetValue('CurrentBuildNumber', $osKey.GetValue('CurrentBuild', '0'))
        $build = 0
        if (-not [int]::TryParse([string]$buildValue, [ref]$build) -or $build -lt 10240) {
            throw ('Compilacion de Windows no reconocida: {0}' -f $buildValue)
        }

        # Microsoft support matrix:
        # Win10 20H2+ (build 19042+) and all Win11 -> .NET Framework 4.8.1.
        # Win10 1607-2004 (build 14393-19041) -> .NET Framework 4.8.
        # Win10 1507/1511 (build 10240-10586) -> .NET Framework 4.6.2.
        if ($build -ge 19042) {
            return [PSCustomObject]@{
                Version = '4.8.1'
                MinimumRelease = 533320
                Url = 'https://go.microsoft.com/fwlink/?linkid=2203305'
                FileName = 'NDP481-x86-x64-AllOS-ENU.exe'
                WindowsBuild = $build
            }
        }
        if ($build -ge 14393) {
            return [PSCustomObject]@{
                Version = '4.8'
                MinimumRelease = 528040
                Url = 'https://go.microsoft.com/fwlink/?linkid=2088631'
                FileName = 'NDP48-x86-x64-AllOS-ENU.exe'
                WindowsBuild = $build
            }
        }
        return [PSCustomObject]@{
            Version = '4.6.2'
            MinimumRelease = 394802
            Url = 'https://go.microsoft.com/fwlink/?linkid=2099468'
            FileName = 'NDP462-KB3151800-x86-x64-AllOS-ENU.exe'
            WindowsBuild = $build
        }
    }
    finally {
        if ($null -ne $osKey) { $osKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Install-JWADDotNetFramework {
    [CmdletBinding()]
    param()

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $displayName = '.NET Framework Runtime'
    $method = 'Direct Microsoft'
    $installerPath = ''

    try {
        $target = Get-JWADDotNetTarget
        $currentRelease = Get-JWADDotNetFrameworkRelease
        $currentName = Get-JWADDotNetReleaseName -Release $currentRelease

        # .NET Framework 4.x is an in-place update. Never attempt to install an
        # older runtime over a newer one, or reinstall an already sufficient one.
        if ($currentRelease -ge [int]$target.MinimumRelease) {
            $timer.Stop()
            return (New-JWADResult -Name $displayName -Status 'ALREADY_PRESENT' -Method 'Registry' -Version $currentName -Seconds $timer.Elapsed.TotalSeconds -ErrorMessage $null)
        }

        if (-not $script:JWADIsAdmin) {
            throw ('Se requiere una consola elevada para instalar .NET Framework {0}. Version actual: {1}.' -f $target.Version, $currentName)
        }

        $installerPath = Join-Path $script:PackageCacheDirectory $target.FileName
        $mustDownload = $true
        if (Test-Path -LiteralPath $installerPath) {
            $existingSignature = Get-AuthenticodeSignature -FilePath $installerPath
            if ($existingSignature.Status -eq 'Valid' -and
                $existingSignature.SignerCertificate -and
                $existingSignature.SignerCertificate.Subject -match '(?i)CN=Microsoft Corporation') {
                $mustDownload = $false
            }
            else {
                Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
            }
        }

        if ($mustDownload) {
            $previousProgressPreference = $ProgressPreference
            try {
                $ProgressPreference = 'SilentlyContinue'
                $downloadParams = @{
                    Uri = $target.Url
                    OutFile = $installerPath
                    TimeoutSec = 600
                    ErrorAction = 'Stop'
                }
                if ($PSVersionTable.PSVersion.Major -eq 5) { $downloadParams.UseBasicParsing = $true }
                Invoke-WebRequest @downloadParams
            }
            finally {
                $ProgressPreference = $previousProgressPreference
            }
        }

        if (-not (Test-Path -LiteralPath $installerPath)) {
            throw 'El instalador oficial de .NET Framework no quedo disponible en la cache.'
        }
        $fileInfo = Get-Item -LiteralPath $installerPath -ErrorAction Stop
        if ($fileInfo.Length -lt 1MB) {
            throw ('El instalador de .NET Framework parece incompleto ({0} bytes).' -f $fileInfo.Length)
        }

        $signature = Get-AuthenticodeSignature -FilePath $installerPath
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(?i)CN=Microsoft Corporation') {
            throw ('La firma Authenticode del instalador .NET no es valida o no pertenece a Microsoft Corporation. Estado: {0}.' -f $signature.Status)
        }

        Write-JWADMessage -Level 'INFO' -Message ('Instalando .NET Framework {0} para Windows build {1}...' -f $target.Version, $target.WindowsBuild)
        $arguments = '/q /norestart /ChainingPackage JWAD'
        $processResult = Invoke-JWADProcess -FilePath $installerPath -ArgumentList $arguments -TimeoutSeconds 1800

        # The .NET Framework redistributable documents 3010 and 1641 as
        # successful installation results that require a restart. The Release
        # DWORD can remain at the pre-update value until Windows completes the
        # pending servicing operation during reboot. Poll briefly before making
        # that distinction; never misreport a documented success code as FAILED.
        $postRelease = Get-JWADDotNetFrameworkRelease
        $postName = Get-JWADDotNetReleaseName -Release $postRelease
        if ($processResult.ExitCode -in @(3010, 1641)) {
            for ($verifyAttempt = 0; $verifyAttempt -lt 5 -and $postRelease -lt [int]$target.MinimumRelease; $verifyAttempt++) {
                Start-Sleep -Seconds 2
                $postRelease = Get-JWADDotNetFrameworkRelease
                $postName = Get-JWADDotNetReleaseName -Release $postRelease
            }
        }

        if ($postRelease -ge [int]$target.MinimumRelease) {
            $resultStatus = 'INSTALLED'
            if ($processResult.ExitCode -in @(3010, 1641)) { $resultStatus = 'INSTALLED_REBOOT_REQUIRED' }
            $timer.Stop()
            return (New-JWADResult -Name $displayName -Status $resultStatus -Method $method -Version $postName -Seconds $timer.Elapsed.TotalSeconds -ErrorMessage $null)
        }

        if ($processResult.ExitCode -in @(3010, 1641)) {
            $pendingMessage = ('Microsoft .NET Framework Setup devolvio ExitCode={0}, que significa que la operacion fue exitosa y requiere reiniciar Windows. El registro todavia muestra .NET Framework {1} (Release {2}); la confirmacion de {3} queda pendiente hasta despues del reinicio. Reinicie el equipo y vuelva a ejecutar JWAD: si la actualizacion se completo, se detectara como ALREADY_PRESENT sin reinstalar.' -f $processResult.ExitCode, $postName, $postRelease, $target.Version)
            $timer.Stop()
            $pendingVersion = '{0} (reinicio requerido; verificacion pendiente)' -f $target.Version
            return (New-JWADResult -Name $displayName -Status 'INSTALLED_REBOOT_REQUIRED' -Method $method -Version $pendingVersion -Seconds $timer.Elapsed.TotalSeconds -ErrorMessage $pendingMessage)
        }

        $output = ('{0}{1}{2}' -f [string]$processResult.Output, [Environment]::NewLine, [string]$processResult.Error).Trim()
        if ($output.Length -gt 1500) { $output = $output.Substring(0, 1500) }
        throw ('El instalador de .NET Framework {0} termino con ExitCode={1}, pero el registro no confirma la version requerida. Release actual={2} ({3}). {4}' -f $target.Version, $processResult.ExitCode, $postRelease, $postName, $output)
    }
    catch {
        $timer.Stop()
        return (New-JWADResult -Name $displayName -Status 'FAILED' -Method $method -Version 'N/A' -Seconds $timer.Elapsed.TotalSeconds -ErrorMessage $_.Exception.Message)
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
Write-JWADStartupBanner
Write-Host '  Fallback: Winget -> Scoop -> Descarga directa verificada' -ForegroundColor DarkCyan

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
$script:JWADPresentationInfo = Get-JWADPresentationInfo
Write-JWADSystemInfo -Info $script:JWADPresentationInfo -Phase 'START'

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
        Name = '.NET Framework Runtime'; Action = 'InstallDotNetFramework'
    },
    [PSCustomObject]@{
        Name = '7-Zip'; WingetId = '7zip.7zip'; WingetCustomArgs = '';
        ScoopName = '7zip'; ScoopBucket = 'main'; GitHubRepo = 'ip7z/7zip'; RegexAsset = '(?i)^7z[0-9]+-x64\.msi$'; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = '';
        DetectPattern = '(?i)^7-Zip'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'WinRAR x64'; WingetId = 'RARLab.WinRAR'; WingetCustomArgs = '/S';
        ScoopName = 'winrar'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '/S';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = 'win.rar GmbH';
        DetectPattern = '(?i)^WinRAR'; DirectPageUrl = 'https://www.rarlab.com/download.htm'; DirectAssetRegex = '(?i)winrar-x64-[0-9]+\.exe'; DirectHashSuffix = ''; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'Microsoft Edge'; WingetId = 'Microsoft.Edge'; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = 'Microsoft Corporation';
        DetectPattern = '(?i)^Microsoft Edge'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
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
        Name = 'VLC Media Player'; WingetId = 'VideoLAN.VLC'; WingetCustomArgs = '';
        ScoopName = 'vlc'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = 'VideoLAN';
        DetectPattern = '(?i)^VLC media player'; DirectPageUrl = 'https://download.videolan.org/vlc/last/win64/'; DirectAssetRegex = '(?i)^vlc-[0-9.]+-win64\.msi$'; DirectHashSuffix = '.sha256'; DirectJsonUrl = ''
    },
    [PSCustomObject]@{
        Name = 'FlyPhotos'; WingetId = ''; WingetCustomArgs = '';
        ScoopName = ''; ScoopBucket = 'main'; GitHubRepo = 'riyasy/FlyPhotos'; RegexAsset = '(?i)^(?!.*(arm64|aarch64|arm)).*(x64|win64|amd64).*\.msi$'; DirectArguments = '';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = '';
        DetectPattern = '(?i)^Fly\s*Photos(?:$|\s)|^FlyPhotos(?:$|\s)'; DirectPageUrl = ''; DirectAssetRegex = ''; DirectHashSuffix = ''; DirectJsonUrl = ''
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
        Name = 'Bulk Crap Uninstaller'; WingetId = 'Klocman.BulkCrapUninstaller'; WingetCustomArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART';
        ScoopName = 'bulk-crap-uninstaller'; ScoopBucket = 'extras'; GitHubRepo = ''; RegexAsset = ''; DirectArguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART';
        ExpectedSHA256 = ''; DirectUrl = ''; DirectFileName = ''; ExpectedSigner = '';
        DetectPattern = '(?i)^(Bulk Crap Uninstaller|BCUninstaller)(?:$|\s)'; DirectPageUrl = 'https://sourceforge.net/projects/bulk-crap-uninstaller/files/latest/download'; DirectAssetRegex = '(?i)BCUninstaller_[0-9.]+_setup\.exe'; DirectHashSuffix = ''; DirectJsonUrl = ''
    }
)

# Total = 14 pasos: 13 aplicaciones originales + instalacion/actualizacion de .NET Framework.
$totalSteps = $apps.Count
$step = 0

Write-Host ''
Write-JWADMessage -Level 'TITLE' -Message 'INICIO DE INSTALACIONES'
foreach ($app in $apps) {
    $step++
    Show-JWADProgress -Current $step -Total $totalSteps -Label $app.Name

    $actionProperty = $app.PSObject.Properties['Action']
    if ($null -ne $actionProperty) {
        if ([string]$actionProperty.Value -eq 'InstallDotNetFramework') {
            $dotNetResult = Install-JWADDotNetFramework
            $script:InstallResults.Add($dotNetResult)
            $dotNetLevel = if ($dotNetResult.estado -eq 'INSTALLED_REBOOT_REQUIRED') { 'WARN' } elseif ($dotNetResult.estado -in @('INSTALLED', 'ALREADY_PRESENT')) { 'OK' } else { 'ERROR' }
            $dotNetMessage = '.NET Framework: {0} mediante {1}; version {2}' -f $dotNetResult.estado, $dotNetResult.metodo_instalacion, $dotNetResult.version_instalada
            if ($dotNetResult.estado -in @('FAILED', 'INSTALLED_REBOOT_REQUIRED') -and -not [string]::IsNullOrWhiteSpace($dotNetResult.error_mensaje)) {
                $dotNetMessage += ' | Detalle: ' + $dotNetResult.error_mensaje
            }
            Write-JWADMessage -Level $dotNetLevel -Message $dotNetMessage
            continue
        }
    }

    [void](Install-UniversalApp -AppName $app.Name -WingetId $app.WingetId -WingetCustomArgs $app.WingetCustomArgs -ScoopName $app.ScoopName -ScoopBucket $app.ScoopBucket -GitHubRepo $app.GitHubRepo -RegexAsset $app.RegexAsset -DirectArguments $app.DirectArguments -ExpectedSHA256 $app.ExpectedSHA256 -DirectUrl $app.DirectUrl -DirectFileName $app.DirectFileName -ExpectedSigner $app.ExpectedSigner -DetectPattern $app.DetectPattern -DirectPageUrl $app.DirectPageUrl -DirectAssetRegex $app.DirectAssetRegex -DirectHashSuffix $app.DirectHashSuffix -DirectJsonUrl $app.DirectJsonUrl)
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
$validationPending = @($script:InstallResults | Where-Object { $_.estado -in @('OUTDATED', 'UNKNOWN', 'PRESENT_UPDATE_UNKNOWN', 'UPDATE_BLOCKED', 'POLICY_MANAGED', 'STORE_MANAGED', 'INSTALLED_REBOOT_REQUIRED') }).Count
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
        instalaciones_exitosas = @($script:InstallResults | Where-Object { $_.estado -like 'INSTALLED*' -or $_.estado -in @('UP_TO_DATE', 'ALREADY_PRESENT', 'STORE_MANAGED', 'POLICY_MANAGED') -or $_.estado -eq 'VALIDATED' }).Count
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
# RESUMEN FINAL - PRESENTACION FRONTEND
# La logica de instalaciones, estados, contadores y reporte JSON no se modifica.
# -----------------------------------------------------------------------------
$finalElapsedSeconds = [Math]::Round($script:JWADStarted.Elapsed.TotalSeconds, 2)
Show-JWADFinalPresentation -Results $script:InstallResults.ToArray() -SystemInfo $script:JWADPresentationInfo -Failed $failed -ValidationPending $validationPending -ReportPath $script:ReportPath -LogPath $script:LogPath -ElapsedSeconds $finalElapsedSeconds
if ($failed -gt 0 -or $validationPending -gt 0) {
    Write-JWADMessage -Level 'WARN' -Message ('El proceso termino con {0} fallos de instalacion y {1} validaciones pendientes. Consulte el JSON/log.' -f $failed, $validationPending)
}
else {
    Write-JWADMessage -Level 'OK' -Message 'No se registraron fallos de instalacion ni validaciones pendientes.'
}
Write-JWADFooterBanner
