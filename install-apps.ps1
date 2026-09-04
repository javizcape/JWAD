#====================================================================
# SCRIPT DE IMPLEMENTACIÓN MASIVA DE APLICACIONES (Windows x64)
#====================================================================
# Versión: 2.1 (Corregida - Septiembre 2026)
# Autor: Arquitectura de Sistemas y Gobernanza Autónoma - Gemini Notebook
# Alojado en: https://javizcape.github.io/.ps1/install-apps.ps1
# Ejecución:  irm https://javizcape.github.io/.ps1/install-apps.ps1 | iex
#====================================================================

$ErrorActionPreference = "Stop"

# Este script está diseñado para ejecutarse ÚNICAMENTE vía:
#   irm https://javizcape.github.io/.ps1/install-apps.ps1 | iex
# Nunca se ejecuta como archivo local, por lo que $PSCommandPath jamás
# existe y no debe usarse. Si cambias de repositorio o de ruta, actualiza
# esta URL antes de publicar.
$ScriptRemoteUrl = "https://javizcape.github.io/.ps1/install-apps.ps1"

$DesktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
$ReportePath = Join-Path $DesktopPath "Reporte_Despliegue.json"
$TiempoTotalSw = [System.Diagnostics.Stopwatch]::StartNew()

# 1. VALIDACIÓN PREVIA Y PRIVILEGIOS DE ADMINISTRADOR
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " INICIANDO ANÁLISIS DE SISTEMA Y CONTROL DE PRIVILEGIOS" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# Validar Arquitectura x64
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
    Write-Host "[ERROR FATAL] Este script solo es compatible con la arquitectura Windows x64 (AMD64)." -ForegroundColor Red
    return
}
Write-Host "[OK] Arquitectura compatible verificada: x64" -ForegroundColor Green

# Validar que la URL remota fue configurada (requisito para poder re-elevar)
if (-not $ScriptRemoteUrl -or $ScriptRemoteUrl -like "*tuusuario*") {
    Write-Host "[ERROR FATAL] ScriptRemoteUrl no está configurada. Edita la variable al inicio del script con la URL pública real antes de publicarlo." -ForegroundColor Red
    return
}

# Validar Privilegios de Administrador
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warning "[ADVERTENCIA] El script no se está ejecutando como Administrador."
    Write-Host "[*] Intentando elevar privilegios (se abrirá una nueva ventana elevada)..." -ForegroundColor Yellow
    try {
        # No hay archivo físico en disco (ejecución vía irm | iex), así que el
        # proceso elevado vuelve a descargar y ejecutar el script desde la URL remota.
        $Comando = "irm $ScriptRemoteUrl | iex"
        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$Comando`"" -Verb RunAs | Out-Null
    } catch {
        Write-Host "[ERROR FATAL] Se requieren privilegios de Administrador para realizar las instalaciones. $($_.Exception.Message)" -ForegroundColor Red
    }
    # Se use 'return' (no 'exit') para no cerrar la ventana de PowerShell
    # original del usuario; la instalación real continúa en la ventana elevada.
    return
}
Write-Host "[OK] Privilegios de Administrador confirmados." -ForegroundColor Green

# 2. DEFINICION DE FUNCIONES DE INSTALACIÓN
function Install-AppViaWinget {
    param (
        [string]$AppName,
        [string]$WingetId,
        [string]$Arguments = ""
    )
    $AppSw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n[*] Iniciando instalación de $AppName ($WingetId) vía Winget..." -ForegroundColor Blue
    try {
        $WingetCheck = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $WingetCheck) {
            throw "Winget no está disponible en este sistema o no se encuentra en el PATH."
        }
        
        $WingetArgs = "install --id `"$WingetId`" --silent --exact --accept-package-agreements --accept-source-agreements --architecture x64"
        if ($Arguments) {
            $WingetArgs += " --override `"$Arguments`""
        }
        
        $Process = Start-Process -FilePath "winget" -ArgumentList $WingetArgs -Wait -NoNewWindow -PassThru
        $ExitCode = $Process.ExitCode
        $AppSw.Stop()
        
        # Códigos de retorno exitosos comunes para instaladores de Windows y winget
        # 0: Éxito, 3010: Reinicio requerido, -1978335186 (0x897D000E): Ya instalado
        if ($ExitCode -eq 0 -or $ExitCode -eq 3010 -or $ExitCode -eq -1978335186) {
            Write-Host "[OK] $AppName se instaló correctamente vía Winget." -ForegroundColor Green
            return [PSCustomObject]@{
                app_name = $AppName
                estado   = "INSTALLED"
                version_instalada = "Última disponible"
                tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2)
                error_mensaje = $null
            }
        } else {
            throw "Winget finalizó con Exit Code: $ExitCode"
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
    Write-Host "`n[*] Buscando última versión de $AppName ($Repo) en GitHub..." -ForegroundColor Blue
    try {
        $ApiUrl = "https://api.github.com/repos/$Repo/releases/latest"
        # Forzar TLS 1.2 o superior
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $Release = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing
        $Version = $Release.tag_name
        Write-Host "[-] Versión más reciente encontrada: $Version" -ForegroundColor Gray
        
        # Filtrar assets compatibles con x64
        $Asset = $Release.assets | Where-Object {
            ($_.name -like "*$AssetFilter*" -or $_.name -like "*x64*" -or $_.name -like "*win64*" -or $_.name -like "*64*") -and
            ($_.name -like "*.exe" -or $_.name -like "*.msi") -and
            ($_.name -notlike "*arm*") -and
            ($_.name -notlike "*mac*") -and
            ($_.name -notlike "*linux*")
        } | Select-Object -First 1
        
        if (-not $Asset) {
            # Búsqueda de respaldo genérica
            $Asset = $Release.assets | Where-Object {
                ($_.name -like "*.exe" -or $_.name -like "*.msi") -and
                ($_.name -notlike "*arm*")
            } | Select-Object -First 1
        }
        
        if (-not $Asset) {
            throw "No se encontró ningún asset ejecutable x64 compatible."
        }
        
        $DownloadUrl = $Asset.browser_download_url
        $FileName = $Asset.name
        $TempPath = Join-Path $env:TEMP $FileName
        
        Write-Host "[-] Descargando $FileName..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempPath -UseBasicParsing
        
        Write-Host "[-] Instalando silenciosamente..." -ForegroundColor Gray
        $ExitCode = 0
        if ($FileName -like "*.msi") {
            $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$TempPath`" /qn /norestart $Arguments" -Wait -NoNewWindow -PassThru
            $ExitCode = $Process.ExitCode
        } else {
            $Process = Start-Process -FilePath $TempPath -ArgumentList $Arguments -Wait -NoNewWindow -PassThru
            $ExitCode = $Process.ExitCode
        }
        
        Remove-Item $TempPath -Force -ErrorAction SilentlyContinue
        $AppSw.Stop()
        
        if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
            Write-Host "[OK] $AppName instalado correctamente desde GitHub." -ForegroundColor Green
            return [PSCustomObject]@{
                app_name = $AppName
                estado   = "INSTALLED"
                version_instalada = $Version
                tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2)
                error_mensaje = $null
            }
        } else {
            throw "El instalador falló con Exit Code: $ExitCode"
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

# 3. VERIFICACIÓN E INSTALACIÓN DE COMPLEMENTOS PREVIOS (REQUISITOS)
Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host " INSTALANDO COMPLEMENTOS DE SISTEMA REQUERIDOS" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# Visual C++ Redistributable x64
$VCRedistResult = Install-AppViaWinget -AppName "Visual C++ Redistributable x64" -WingetId "Microsoft.VCRedist.2015+.x64"

# .NET Framework (DISM habilitación)
$NetSw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "[*] Habilitando .NET Framework mediante DISM..." -ForegroundColor Blue
try {
    $DISMProcess = Start-Process -FilePath "dism.exe" -ArgumentList "/online /enable-feature /featurename:NetFX4 /all /norestart" -Wait -NoNewWindow -PassThru
    $NetSw.Stop()
    if ($DISMProcess.ExitCode -eq 0 -or $DISMProcess.ExitCode -eq 3010) {
        Write-Host "[OK] .NET Framework habilitado con éxito." -ForegroundColor Green
        $NetResult = [PSCustomObject]@{
            app_name = ".NET Framework"
            estado   = "INSTALLED"
            version_instalada = "Habilitado por DISM"
            tiempo_instalacion_segundos = [Math]::Round($NetSw.Elapsed.TotalSeconds, 2)
            error_mensaje = $null
        }
    } else {
        throw "DISM falló con código: $($DISMProcess.ExitCode)"
    }
} catch {
    $NetSw.Stop()
    Write-Host "[FALLO] No se pudo habilitar .NET Framework: $_" -ForegroundColor Red
    $NetResult = [PSCustomObject]@{
        app_name = ".NET Framework"
        estado   = "FAILED"
        version_instalada = "N/A"
        tiempo_instalacion_segundos = [Math]::Round($NetSw.Elapsed.TotalSeconds, 2)
        error_mensaje = $_.Exception.Message
    }
}

# Java Runtime Environment (JRE) x64
$JavaResult = Install-AppViaWinget -AppName "Java Runtime Environment" -WingetId "Oracle.JRE"

# 4. INSTALACIÓN DE LAS 11 APLICACIONES PRINCIPALES
Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host " INICIANDO IMPLEMENTACIÓN DE LAS 11 APLICACIONES PRINCIPALES" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

$ResultadosList = [System.Collections.Generic.List[PSCustomObject]]::new()

# Agregar complementos de sistema a la lista de reportes
$ResultadosList.Add($VCRedistResult)
$ResultadosList.Add($NetResult)
$ResultadosList.Add($JavaResult)

# App 1: 7-Zip (Winget)
$ResultadosList.Add((Install-AppViaWinget -AppName "7-Zip" -WingetId "7zip.7zip"))

# App 2: Bulk Crap Uninstaller (Winget / GitHub Híbrido)
$ResultadosList.Add((Install-AppViaWinget -AppName "Bulk Crap Uninstaller" -WingetId "BCUninstaller.BulkCrapUninstaller" -Arguments "/SILENT"))

# App 3: SumatraPDF (Winget)
$ResultadosList.Add((Install-AppViaWinget -AppName "SumatraPDF" -WingetId "SumatraPDF.SumatraPDF"))

# App 4: AB Download Manager (GitHub - Descarga Directa)
$ResultadosList.Add((Install-AppViaDirectUrl -AppName "AB Download Manager" -Repo "amir1376/ab-download-manager" -AssetFilter "Setup" -Arguments "/SILENT"))

# App 5: WinRAR x64 (ES) (Winget)
$ResultadosList.Add((Install-AppViaWinget -AppName "WinRAR x64" -WingetId "RARLab.WinRAR" -Arguments "/S"))

# App 6: VLC Media Player (Winget)
$ResultadosList.Add((Install-AppViaWinget -AppName "VLC Media Player" -WingetId "VideoLAN.VLC" -Arguments "/S"))

# App 7: Google Chrome (Winget)
$ResultadosList.Add((Install-AppViaWinget -AppName "Google Chrome" -WingetId "Google.Chrome" -Arguments "/silent /install"))

# App 8: Mozilla Firefox (Winget)
$ResultadosList.Add((Install-AppViaWinget -AppName "Mozilla Firefox" -WingetId "Mozilla.Firefox" -Arguments "-ms"))

# App 9: Mullvad Browser (Winget / GitHub Híbrido)
$ResultadosList.Add((Install-AppViaWinget -AppName "Mullvad Browser" -WingetId "Mullvad.MullvadBrowser" -Arguments "/S"))

# App 10: Microsoft Edge para Empresas (Winget)
$ResultadosList.Add((Install-AppViaWinget -AppName "Microsoft Edge" -WingetId "Microsoft.Edge" -Arguments "/silent"))

# App 11: FlyPhotos (GitHub - Descarga Directa)
$ResultadosList.Add((Install-AppViaDirectUrl -AppName "FlyPhotos" -Repo "riyasy/FlyPhotos" -AssetFilter "Setup" -Arguments "/S"))

# 5. RECOPILACIÓN DE TELEMETRÍA DEL HARDWARE Y DEL SISTEMA
Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host " RECOPILANDO TELEMETRÍA Y ESPECIFICACIONES DEL SISTEMA" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$OperatingSystem = Get-CimInstance Win32_OperatingSystem
$ProcessorInfo = Get-CimInstance Win32_Processor

$Fabricante = $ComputerSystem.Manufacturer
$Modelo = $ComputerSystem.Model
$Procesador = $ProcessorInfo.Name
$Arquitectura = $env:PROCESSOR_ARCHITECTURE

# RAM total y en uso
$RAMTotalBytes = ($ComputerSystem.TotalPhysicalMemory)
if (-not $RAMTotalBytes) {
    $RAMTotalBytes = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
}
$RAMTotalGB = [Math]::Round($RAMTotalBytes / 1GB, 2)
$RAMLibreKB = $OperatingSystem.FreePhysicalMemory
$RAMTotalKB = $OperatingSystem.TotalVisibleMemorySize
$RAMUsadaKB = $RAMTotalKB - $RAMLibreKB
$RAMUsoPct = [Math]::Round(($RAMUsadaKB / $RAMTotalKB) * 100, 2)

# Almacenamiento total y en uso (C:)
$DiscoC = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$DiscoTotalGB = [Math]::Round($DiscoC.Size / 1GB, 2)
$DiscoLibreGB = [Math]::Round($DiscoC.FreeSpace / 1GB, 2)
$DiscoUsadoGB = $DiscoTotalGB - $DiscoLibreGB
$DiscoUsoPct = [Math]::Round(($DiscoUsadoGB / $DiscoTotalGB) * 100, 2)

# Diagnósticos de Temperatura
$LecturasTemp = [System.Collections.Generic.List[PSCustomObject]]::new()
$TempFinal = $null

# Método 1: CIM_ThermalZone
try {
    $CimZones = Get-CimInstance -Namespace "root/cimv2" -ClassName "Win32_TemperatureSensor" -ErrorAction Stop
    if ($CimZones -and $CimZones.CurrentReading) {
        $ValCelsius = $CimZones.CurrentReading
        $LecturasTemp.Add([PSCustomObject]@{
            metodo = "CIM_ThermalZone"
            valor_celsius = $ValCelsius
            estado = "SUCCESS"
        })
        $TempFinal = $ValCelsius
    } else {
        throw "Sin lecturas en Win32_TemperatureSensor"
    }
} catch {
    $LecturasTemp.Add([PSCustomObject]@{
        metodo = "CIM_ThermalZone"
        valor_celsius = $null
        estado = "UNSUPPORTED"
    })
}

# Método 2: WMI_MSAcpi
try {
    $WmiZones = Get-CimInstance -Namespace "root/wmi" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction Stop
    if ($WmiZones) {
        # La lectura es en décimas de Kelvin (ej: 3002 = 300.2 Kelvin)
        $ValCelsius = [Math]::Round((($WmiZones.CurrentTemperature) - 2732) / 10, 2)
        $LecturasTemp.Add([PSCustomObject]@{
            metodo = "WMI_MSAcpi"
            valor_celsius = $ValCelsius
            estado = "SUCCESS"
        })
        if ($null -eq $TempFinal) { $TempFinal = $ValCelsius }
    } else {
        throw "Sin lecturas en MSAcpi_ThermalZoneTemperature"
    }
} catch {
    $LecturasTemp.Add([PSCustomObject]@{
        metodo = "WMI_MSAcpi"
        valor_celsius = $null
        estado = "HARDWARE_LOCKED"
    })
}

# Detener el cronómetro total
$TiempoTotalSw.Stop()
$TiempoTotalSegundos = [Math]::Round($TiempoTotalSw.Elapsed.TotalSeconds, 2)

# 6. EXPORTAR REPORTE JSON
$ReporteJSON = [Ordered]@{
    timestamp = (Get-Date -Format "o")
    specs_computador = [Ordered]@{
        fabricante = $Fabricante
        modelo     = $Modelo
        procesador = $Procesador
        arquitectura = $Arquitectura
        memoria_ram_total_gb = $RAMTotalGB
        uso_actual_ram_porcentaje = $RAMUsoPct
        almacenamiento_total_gb = $DiscoTotalGB
        uso_actual_almacenamiento_porcentaje = $DiscoUsoPct
    }
    diagnosticos_temperatura = [Ordered]@{
        lecturas = $LecturasTemp
        temperatura_final_corroborada = $TempFinal
    }
    reporte_instalacion = [Ordered]@{
        tiempo_total_ejecucion_segundos = $TiempoTotalSegundos
        resultado_aplicaciones = $ResultadosList
    }
}

$ReporteJSON | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportePath -Encoding utf8 -Force

# 7. VISUALIZACIÓN DEL REPORTE FINAL EN CONSOLA
Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host " REPORTE FINAL DE DESPLIEGUE Y TELEMETRÍA" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green

Write-Host "[-] Fecha y Hora: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")"
Write-Host "[-] Equipo: $Fabricante $Modelo"
Write-Host "[-] Procesador: $Procesador"
Write-Host "[-] Memoria RAM: $RAMTotalGB GB (En uso: $RAMUsoPct %)"
Write-Host "[-] Disco (C:): $DiscoTotalGB GB (En uso: $DiscoUsoPct %)"
if ($null -ne $TempFinal) {
    Write-Host "[-] Temperatura CPU: $TempFinal °C" -ForegroundColor Yellow
} else {
    Write-Host "[-] Temperatura CPU: No disponible (Hardware bloqueado o no soportado)" -ForegroundColor Gray
}
Write-Host "[-] Tiempo Total de Ejecución: $TiempoTotalSegundos segundos" -ForegroundColor Cyan
Write-Host "[-] Archivo de Reporte Creado en: $ReportePath" -ForegroundColor Green

Write-Host "`n[-] Estado de las Instalaciones:" -ForegroundColor Gray
foreach ($App in $ResultadosList) {
    $Color = "Green"
    if ($App.estado -eq "FAILED") { $Color = "Red" }
    Write-Host "    * [$($App.estado)] $($App.app_name) - Versión: $($App.version_instalada) ($($App.tiempo_instalacion_segundos)s)" -ForegroundColor $Color
}
Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host " Proceso de automatización finalizado con éxito." -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
