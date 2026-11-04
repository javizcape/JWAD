#====================================================================
# SCRIPT DE IMPLEMENTACION MASIVA DE APLICACIONES (Windows x64)
#====================================================================
# Version: 3.0 (Enterprise Resilient - Septiembre 2026)
# Autor: Arquitectura de Sistemas y Gobernanza Autonoma - JWAD
# Alojado en: https://javizcape.github.io/JWAD/JWAD.ps1
# Ejecucion:  irm https://javizcape.github.io/JWAD/JWAD.ps1 | iex
#====================================================================

$ErrorActionPreference = "Stop"

# Force TLS 1.2 desde el inicio de la sesion
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptRemoteUrl = "https://javizcape.github.io/JWAD/JWAD.ps1"
$DesktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
$ReportePath = Join-Path $DesktopPath "Reporte_Despliegue.json"
$TiempoTotalSw = [System.Diagnostics.Stopwatch]::StartNew()

# Variables de estado global para auditoria incremental (Hot-Writing)
$Global:ResultadosList = [System.Collections.Generic.List[PSCustomObject]]::new()
$Global:Fabricante = "Desconocido"
$Global:Modelo = "Desconocido"
$Global:Procesador = "Desconocido"
$Global:RAMTotalGB = 0
$Global:RAMUsoPct = 0
$Global:DiscoTotalGB = 0
$Global:DiscoUsoPct = 0
$Global:TempFinal = $null

#====================================================================
# CAPA DE PRESENTACION - Banner ASCII Puro
#====================================================================
$JWADBannerGrande = @(
    '     ___        ___    ____  ',
    '    | \ \      / / \  |  _ \ ',
    ' _  | |\ \ /\ / / _ \ | | | |',
    '| |_| | \ V  V / ___ \| |_| |',
    ' \___/   \_/\_/_/   \_\____/ '
)
$JWADGradiente = @('Cyan', 'Blue', 'White', 'Blue', 'Cyan')

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
for ($i = 0; $i -lt $JWADBannerGrande.Count; $i++) {
    Write-Host "  $($JWADBannerGrande[$i])" -ForegroundColor $JWADGradiente[$i]
}
Write-Host "         WINDOWS APP DEPLOYER - v3.0" -ForegroundColor DarkCyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""

# 1. VALIDACION PREVIA Y CONTROL DE PRIVILEGIOS
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " INICIANDO ANALISIS DE SISTEMA Y CONTROL DE PRIVILEGIOS" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
    Write-Host "[ERROR FATAL] Este script solo es compatible con la arquitectura Windows x64 (AMD64)." -ForegroundColor Red
    return
}
Write-Host "[OK] Arquitectura compatible verificada: x64" -ForegroundColor Green

if (-not $ScriptRemoteUrl -or $ScriptRemoteUrl -like "*tuusuario*") {
    Write-Host "[ERROR FATAL] ScriptRemoteUrl no esta configurada adecuadamente." -ForegroundColor Red
    return
}

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warning "[ADVERTENCIA] El script no se esta ejecutando como Administrador."
    Write-Host "[*] Intentando elevar privilegios (se abrira una nueva ventana elevada)..." -ForegroundColor Yellow
    try {
        $Comando = "irm $ScriptRemoteUrl | iex"
        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$Comando`"" -Verb RunAs | Out-Null
    } catch {
        Write-Host "[ERROR FATAL] Se requieren privilegios de Administrador. $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}
Write-Host "[OK] Privilegios de Administrador confirmados." -ForegroundColor Green

#====================================================================
# FUNCIONES NUCLEO (Hot-Writing, Environment Refresh, Timeouts)
#====================================================================

function Update-Environment {
    foreach ($level in "Machine", "User") {
        [Environment]::GetEnvironmentVariables($level).GetEnumerator() | ForEach-Object {
            if ($_.Key -eq 'Path') {
                $env:Path += ";$($_.Value)"
            }
        }
    }
}

function Save-IncrementalReport {
    try {
        $ReporteJSON = [Ordered]@{
            timestamp = (Get-Date -Format "o")
            specs_computador = [Ordered]@{
                fabricante = $Global:Fabricante
                modelo     = $Global:Modelo
                procesador = $Global:Procesador
                memoria_ram_total_gb = $Global:RAMTotalGB
                uso_actual_ram_porcentaje = $Global:RAMUsoPct
                almacenamiento_total_gb = $Global:DiscoTotalGB
                uso_actual_almacenamiento_porcentaje = $Global:DiscoUsoPct
            }
            diagnosticos_temperatura = [Ordered]@{
                temperatura_final_corroborada = $Global:TempFinal
            }
            reporte_instalacion = [Ordered]@{
                tiempo_transcurrido_segundos = [Math]::Round($TiempoTotalSw.Elapsed.TotalSeconds, 2)
                resultado_aplicaciones = $Global:ResultadosList
            }
        }
        $ReporteJSON | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportePath -Encoding utf8 -Force
    } catch {
        # Escritura silenciosa para evitar pausar el flujo principal
    }
}

function Install-AppViaWinget {
    param (
        [string]$AppName,
        [string]$WingetId,
        [string]$Arguments = ""
    )
    $AppSw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n[*] Verificando estado de $AppName ($WingetId)..." -ForegroundColor Blue
    try {
        $WingetCheck = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $WingetCheck) {
            throw "Winget no esta disponible en este sistema."
        }

        $ListadoInstalados = & winget list --id "$WingetId" --exact --accept-source-agreements 2>$null | Out-String
        $YaInstalado = $ListadoInstalados -match [regex]::Escape($WingetId)

        if ($YaInstalado) {
            Write-Host "[-] $AppName ya esta instalado. Verificando si existe una version mas reciente..." -ForegroundColor Gray
            $WingetArgs = "upgrade --id `"$WingetId`" --silent --exact --accept-package-agreements --accept-source-agreements"
        } else {
            Write-Host "[-] $AppName no esta instalado. Procediendo con instalacion silenciosa..." -ForegroundColor Gray
            $WingetArgs = "install --id `"$WingetId`" --silent --exact --accept-package-agreements --accept-source-agreements --architecture x64"
        }
        if ($Arguments) {
            $WingetArgs += " --override `"$Arguments`""
        }

        # Ejecución anti-colgamiento con Timeout de 10 minutos (600,000 ms)
        $Process = Start-Process -FilePath "winget" -ArgumentList $WingetArgs -PassThru -NoNewWindow
        if (-not $Process.WaitForExit(600000)) {
            $Process | Stop-Process -Force -ErrorAction SilentlyContinue
            throw "TIMEOUT: La instalacion excedio los 10 minutos y el proceso fue terminado."
        }

        $ExitCode = $Process.ExitCode
        $AppSw.Stop()

        $CodigosExito = @(0, 3010, -1978335186, -1978335189)
        if ($CodigosExito -contains $ExitCode) {
            $Estado = "INSTALLED"
            if ($ExitCode -eq -1978335186 -or $ExitCode -eq -1978335189) { $Estado = "YA_ACTUALIZADO" }
            elseif ($ExitCode -eq 3010) { $Estado = "INSTALLED_REINICIO_PENDIENTE" }

            Write-Host "[OK] ${AppName}: $Estado" -ForegroundColor Green
            Update-Environment
            return [PSCustomObject]@{
                app_name = $AppName
                estado   = $Estado
                version_instalada = "Ultima disponible"
                tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2)
                error_mensaje = $null
            }
        } else {
            throw "Winget finalizo con Exit Code: $ExitCode"
        }
    } catch {
        $AppSw.Stop()
        Write-Host "[FALLO] Error al instalar ${AppName}: $_" -ForegroundColor Red
        return [PSCustomObject]@{
            app_name = $AppName
            estado   = "FAILED"
            version_instalada = "N/A"
            tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2)
            error_mensaje = $_.Exception.Message
        }
    }
}

function Install-AppViaDirectUrl {
    param (
        [string]$AppName,
        [string]$Repo,
        [string]$AssetFilter,
        [string]$Arguments = ""
    )
    $AppSw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n[*] Consultando ultima version de $AppName ($Repo) en GitHub..." -ForegroundColor Blue
    try {
        $ApiUrl = "https://api.github.com/repos/$Repo/releases/latest"
        $Release = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing
        $VersionRemota = $Release.tag_name -replace '^v', ''
        Write-Host "[-] Version publicada: $VersionRemota" -ForegroundColor Gray

        $RutasRegistro = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $Instalado = Get-ItemProperty -Path $RutasRegistro -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$AppName*" } |
            Select-Object -First 1

        if ($Instalado -and $Instalado.DisplayVersion) {
            $VersionLocal = $Instalado.DisplayVersion
            Write-Host "[-] $AppName instalado (version local: $VersionLocal)." -ForegroundColor Gray
            $EsVersionVigente = $false
            try {
                $EsVersionVigente = [version]$VersionLocal -ge [version]$VersionRemota
            } catch {
                $EsVersionVigente = ($VersionLocal -eq $VersionRemota)
            }
            if ($EsVersionVigente) {
                $AppSw.Stop()
                Write-Host "[OK] $AppName se encuentra en la ultima version disponible." -ForegroundColor Green
                return [PSCustomObject]@{
                    app_name = $AppName
                    estado   = "YA_ACTUALIZADO"
                    version_instalada = $VersionLocal
                    tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2)
                    error_mensaje = $null
                }
            }
        }

        $Asset = $Release.assets | Where-Object {
            ($_.name -like "*$AssetFilter*" -or $_.name -like "*x64*" -or $_.name -like "*win64*" -or $_.name -like "*64*") -and
            ($_.name -like "*.exe" -or $_.name -like "*.msi") -and
            ($_.name -notlike "*arm*") -and ($_.name -notlike "*mac*") -and ($_.name -notlike "*linux*")
        } | Select-Object -First 1

        if (-not $Asset) {
            $Asset = $Release.assets | Where-Object { ($_.name -like "*.exe" -or $_.name -like "*.msi") -and ($_.name -notlike "*arm*") } | Select-Object -First 1
        }
        if (-not $Asset) { throw "No se encontro un asset ejecutable x64 compatible." }

        $DownloadUrl = $Asset.browser_download_url
        $FileName = $Asset.name
        $TempPath = Join-Path $env:TEMP $FileName

        Write-Host "[-] Descargando $FileName..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempPath -UseBasicParsing

        Write-Host "[-] Instalando silenciosamente..." -ForegroundColor Gray
        
        if ($FileName -like "*.msi") {
            $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$TempPath`" /qn /norestart" -PassThru -NoNewWindow
        } else {
            $Process = Start-Process -FilePath $TempPath -ArgumentList $Arguments -PassThru -NoNewWindow
        }

        # Timeout de 10 minutos (600,000 ms)
        if (-not $Process.WaitForExit(600000)) {
            $Process | Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-Item $TempPath -Force -ErrorAction SilentlyContinue
            throw "TIMEOUT: La instalacion de GitHub excedio los 10 minutos."
        }

        $ExitCode = $Process.ExitCode
        Remove-Item $TempPath -Force -ErrorAction SilentlyContinue
        $AppSw.Stop()

        if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
            Write-Host "[OK] $AppName instalado correctamente." -ForegroundColor Green
            Update-Environment
            return [PSCustomObject]@{
                app_name = $AppName
                estado   = "INSTALLED"
                version_instalada = $VersionRemota
                tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2)
                error_mensaje = $null
            }
        } else {
            throw "El instalador fallo con Exit Code: $ExitCode"
        }
    } catch {
        $AppSw.Stop()
        Write-Host "[FALLO] Error al instalar ${AppName}: $_" -ForegroundColor Red
        return [PSCustomObject]@{
            app_name = $AppName
            estado   = "FAILED"
            version_instalada = "N/A"
            tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2)
            error_mensaje = $_.Exception.Message
        }
    }
}

function Show-JWADProgressBar {
    param (
        [int]$Current,
        [int]$Total,
        [string]$Label
    )
    $Ancho = 28
    $Fraccion = if ($Total -gt 0) { $Current / $Total } else { 0 }
    $Relleno = [Math]::Round($Ancho * $Fraccion)
    if ($Relleno -gt $Ancho) { $Relleno = $Ancho }
    $Vacio = $Ancho - $Relleno
    $SegundosTranscurridos = [Math]::Round($TiempoTotalSw.Elapsed.TotalSeconds, 1)

    Write-Host ""
    Write-Host ("  [{0,2}/{1,2}] {2}" -f $Current, $Total, $Label) -ForegroundColor Cyan
    Write-Host "  [" -ForegroundColor Blue -NoNewline
    if ($Relleno -gt 0) { Write-Host ('#' * $Relleno) -ForegroundColor Green -NoNewline }
    if ($Vacio -gt 0) { Write-Host ('.' * $Vacio) -ForegroundColor DarkBlue -NoNewline }
    Write-Host "] " -ForegroundColor Blue -NoNewline
    Write-Host ("{0}s transcurridos" -f $SegundosTranscurridos) -ForegroundColor White
}

#====================================================================
# BLOQUE PRINCIPAL DE EJECUCION CON PROTECCION FINALLY
#====================================================================
try {
    $JWADPasoActual = 0
    $JWADPasosTotal = 14

    Write-Host "`n=========================================================" -ForegroundColor Cyan
    Write-Host " INSTALANDO COMPLEMENTOS DE SISTEMA REQUERIDOS" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    # Complemento 1: Visual C++
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Visual C++ Redistributable x64"
    $Res = Install-AppViaWinget -AppName "Visual C++ Redistributable x64" -WingetId "Microsoft.VCRedist.2015+.x64"
    $Global:ResultadosList.Add($Res); Save-IncrementalReport

    # Complemento 2: .NET Framework (Validación)
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label ".NET Framework (validacion)"
    $NetSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $NetRelease = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction Stop).Release
        $NetSw.Stop()
        $EstadoNet = if ($NetRelease -ge 528040) { "YA_ACTUALIZADO" } else { "DESACTUALIZADO" }
        $Global:ResultadosList.Add([PSCustomObject]@{
            app_name = ".NET Framework"
            estado   = $EstadoNet
            version_instalada = "Release $NetRelease"
            tiempo_instalacion_segundos = [Math]::Round($NetSw.Elapsed.TotalSeconds, 2)
            error_mensaje = $null
        })
    } catch {
        $NetSw.Stop()
        $Global:ResultadosList.Add([PSCustomObject]@{
            app_name = ".NET Framework"
            estado   = "FAILED"
            version_instalada = "N/A"
            tiempo_instalacion_segundos = [Math]::Round($NetSw.Elapsed.TotalSeconds, 2)
            error_mensaje = $_.Exception.Message
        })
    }
    Save-IncrementalReport

    # Complemento 3: Java JRE
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Java Runtime Environment (JRE) x64"
    $Res = Install-AppViaWinget -AppName "Java Runtime Environment" -WingetId "EclipseAdoptium.Temurin.21.JRE"
    $Global:ResultadosList.Add($Res); Save-IncrementalReport

    # 11 APLICACIONES PRINCIPALES
    Write-Host "`n=========================================================" -ForegroundColor Cyan
    Write-Host " INICIANDO IMPLEMENTACION DE LAS 11 APLICACIONES PRINCIPALES" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    # App 1: 7-Zip
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "7-Zip"
    $Global:ResultadosList.Add((Install-AppViaWinget "7-Zip" "7zip.7zip")); Save-IncrementalReport

    # App 2: Bulk Crap Uninstaller
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Bulk Crap Uninstaller"
    $Global:ResultadosList.Add((Install-AppViaWinget "Bulk Crap Uninstaller" "Klocman.BulkCrapUninstaller" "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART")); Save-IncrementalReport

    # App 3: SumatraPDF
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "SumatraPDF"
    $Global:ResultadosList.Add((Install-AppViaWinget "SumatraPDF" "SumatraPDF.SumatraPDF")); Save-IncrementalReport

    # App 4: AB Download Manager
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "AB Download Manager"
    $Global:ResultadosList.Add((Install-AppViaDirectUrl "AB Download Manager" "amir1376/ab-download-manager" "Setup" "/S")); Save-IncrementalReport

    # App 5: WinRAR
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "WinRAR x64"
    $Global:ResultadosList.Add((Install-AppViaWinget "WinRAR x64" "RARLab.WinRAR" "/S")); Save-IncrementalReport

    # App 6: VLC
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "VLC Media Player"
    $Global:ResultadosList.Add((Install-AppViaWinget "VLC Media Player" "VideoLAN.VLC" "/S")); Save-IncrementalReport

    # App 7: Chrome
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Google Chrome"
    $Global:ResultadosList.Add((Install-AppViaWinget "Google Chrome" "Google.Chrome" "/silent /install")); Save-IncrementalReport

    # App 8: Firefox
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Mozilla Firefox"
    $Global:ResultadosList.Add((Install-AppViaWinget "Mozilla Firefox" "Mozilla.Firefox" "-ms")); Save-IncrementalReport

    # App 9: Mullvad Browser
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Mullvad Browser"
    $Global:ResultadosList.Add((Install-AppViaWinget "Mullvad Browser" "MullvadVPN.MullvadBrowser" "/S")); Save-IncrementalReport

    # App 10: Microsoft Edge
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Microsoft Edge"
    $Global:ResultadosList.Add((Install-AppViaWinget "Microsoft Edge" "Microsoft.Edge" "/silent")); Save-IncrementalReport

    # App 11: FlyPhotos
    $JWADPasoActual++
    Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "FlyPhotos"
    $Global:ResultadosList.Add((Install-AppViaDirectUrl "FlyPhotos" "riyasy/FlyPhotos" "Setup")); Save-IncrementalReport

    # TELEMETRIA Y HARDWARE
    Write-Host "`n=========================================================" -ForegroundColor Cyan
    Write-Host " RECOPILANDO TELEMETRIA Y ESPECIFICACIONES DEL SISTEMA" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan

    $ComputerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $OperatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $ProcessorInfo = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue

    $Global:Fabricante = $ComputerSystem.Manufacturer
    $Global:Modelo = $ComputerSystem.Model
    $Global:Procesador = $ProcessorInfo.Name

    $RAMTotalBytes = $ComputerSystem.TotalPhysicalMemory
    if (-not $RAMTotalBytes) { $RAMTotalBytes = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum }
    $Global:RAMTotalGB = [Math]::Round($RAMTotalBytes / 1GB, 2)
    
    $RAMLibreKB = $OperatingSystem.FreePhysicalMemory
    $RAMTotalKB = $OperatingSystem.TotalVisibleMemorySize
    $RAMUsadaKB = $RAMTotalKB - $RAMLibreKB
    $Global:RAMUsoPct = [Math]::Round(($RAMUsadaKB / $RAMTotalKB) * 100, 2)

    $DiscoC = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    $Global:DiscoTotalGB = [Math]::Round($DiscoC.Size / 1GB, 2)
    $DiscoLibreGB = [Math]::Round($DiscoC.FreeSpace / 1GB, 2)
    $DiscoUsadoGB = $Global:DiscoTotalGB - $DiscoLibreGB
    $Global:DiscoUsoPct = [Math]::Round(($DiscoUsadoGB / $Global:DiscoTotalGB) * 100, 2)

    # Diagnostico Térmico Seguro
    try {
        $WmiZones = Get-CimInstance -Namespace "root/wmi" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction Stop
        if ($WmiZones) {
            $Global:TempFinal = [Math]::Round((($WmiZones.CurrentTemperature) - 2732) / 10, 2)
        }
    } catch {
        $Global:TempFinal = $null
    }

} finally {
    # 7. EXPORTACION FINAL Y CIERRE RESILIENTE
    $TiempoTotalSw.Stop()
    Save-IncrementalReport

    Write-Host "`n=========================================================" -ForegroundColor Green
    Write-Host " REPORTE FINAL DE DESPLIEGUE Y TELEMETRIA" -ForegroundColor Green
    Write-Host "=========================================================" -ForegroundColor Green

    Write-Host "[-] Fecha y Hora: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
    Write-Host "[-] Equipo: $Global:Fabricante $Global:Modelo"
    Write-Host "[-] Procesador: $Global:Procesador"
    Write-Host "[-] Memoria RAM: $Global:RAMTotalGB GB (En uso: $Global:RAMUsoPct %)"
    Write-Host "[-] Disco (C:): $Global:DiscoTotalGB GB (En uso: $Global:DiscoUsoPct %)"
    if ($null -ne $Global:TempFinal) {
        Write-Host "[-] Temperatura CPU: $Global:TempFinal C" -ForegroundColor Yellow
    } else {
        Write-Host "[-] Temperatura CPU: No disponible (Hardware bloqueado)" -ForegroundColor Gray
    }
    Write-Host "[-] Tiempo Total: $([Math]::Round($TiempoTotalSw.Elapsed.TotalSeconds, 2)) segundos" -ForegroundColor Cyan
    Write-Host "[-] Reporte JSON Preservado en: $ReportePath" -ForegroundColor Green

    Write-Host "`n[-] Estado de las Instalaciones:" -ForegroundColor Gray
    foreach ($App in $Global:ResultadosList) {
        $Color = "Green"
        if ($App.estado -eq "FAILED") { $Color = "Red" }
        elseif ($App.estado -eq "DESACTUALIZADO") { $Color = "Yellow" }
        Write-Host "    * [$($App.estado)] $($App.app_name) - Version: $($App.version_instalada) ($($App.tiempo_instalacion_segundos)s)" -ForegroundColor $Color
    }
    Write-Host "`n=========================================================" -ForegroundColor Green
    Write-Host " Proceso finalizado." -ForegroundColor Green
    Write-Host "=========================================================" -ForegroundColor Green

    $JWADBannerPequeno = @(
        '    ___      ___   ___  ',
        ' _ | \ \    / /_\ |   \ ',
        '| || |\ \/\/ / _ \| |) |',
        ' \__/  \_/\_/_/ \_\___/ '
    )
    Write-Host ""
    foreach ($JWADLinea in $JWADBannerPequeno) { Write-Host "  $JWADLinea" -ForegroundColor DarkGray }
    Write-Host "  javizcape.github.io/JWAD" -ForegroundColor DarkGray
    Write-Host ""
}
