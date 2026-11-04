#====================================================================
# SCRIPT DE IMPLEMENTACION MASIVA DE APLICACIONES (Windows x64)
#====================================================================
# Version: 3.1 (Enterprise Resilient & Parsing Fixed - Noviembre 2026)
# Autor: Arquitectura de Sistemas - JWAD
# Alojado en: https://javizcape.github.io/JWAD/JWAD.ps1
# Ejecucion:  irm https://javizcape.github.io/JWAD/JWAD.ps1 | iex
#====================================================================

$ErrorActionPreference = "Stop"

# Force TLS 1.2 desde el inicio de la sesion
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptRemoteUrl = "https://javizcape.github.io/JWAD/JWAD.ps1"
$DesktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
$ReportePath = Join-Path$DesktopPath "Reporte_Despliegue.json"
$TiempoTotalSw = [System.Diagnostics.Stopwatch]::StartNew()

# Variables de estado global para auditoria incremental (Hot-Writing)
$Global:ResultadosList = [System.Collections.Generic.List[PSCustomObject]]::new()$Global:Fabricante = "Desconocido"
$Global:Modelo = "Desconocido"
$Global:Procesador = "Desconocido"
$Global:RAMTotalGB = 0$Global:RAMUsoPct = 0
$Global:DiscoTotalGB = 0$Global:DiscoUsoPct = 0
$Global:TempFinal =$null

#====================================================================
# CAPA DE PRESENTACION - Banner ASCII Puro
#====================================================================
$JWADBannerGrande = @( '     ___        ___    ____  ', '    \vert{} \ \      / / \  \vert{}  _ \ ', ' _  \vert{} \vert{}\ \ /\ / / _ \ \vert{} \vert{} \vert{} \vert{}', '\vert{} \vert{}_\vert{} \vert{} \ V  V / ___ \Vert{} \vert{}_\vert{} \vert{}', ' \___/   \_/\_/_/   \_\____/ ' )$JWADGradiente = @('Cyan', 'Blue', 'White', 'Blue', 'Cyan')

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
for ($i = 0; $i -lt $JWADBannerGrande.Count; $i++) {
    Write-Host "  $($JWADBannerGrande[$i])" -ForegroundColor $JWADGradiente[$i]
}
Write-Host "         WINDOWS APP DEPLOYER - v3.1" -ForegroundColor DarkCyan
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

if (-not $ScriptRemoteUrl -or$ScriptRemoteUrl -like "*tuusuario*") {
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
# FUNCIONES NUCLEO (Bootstrapper, Hot-Writing, Timeouts)
#====================================================================

function Update-Environment {
    foreach ($level in "Machine", "User") {
        [Environment]::GetEnvironmentVariables($level).GetEnumerator() | ForEach-Object {
            if ($_.Key -eq 'Path') {$env:Path += ";$($_.Value)"
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
        $ReporteJSON \vert{} ConvertTo-Json -Depth 5 \vert{} Out-File -FilePath$ReportePath -Encoding utf8 -Force
    } catch {
        # Escritura silenciosa para evitar pausar el flujo
    }
}

function Install-WingetBootstrapper {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "`n[*] Winget no detectado en el sistema. Iniciando inyeccion de dependencias..." -ForegroundColor Yellow
        try {
            $TempDir = $env:TEMP
            $ProgressPreference = 'SilentlyContinue'

            Write-Host "[-] Instalando framework Microsoft.UI.Xaml..." -ForegroundColor Gray
            $XamlUrl = "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx"
            $XamlPath = Join-Path $TempDir "UIXaml.appx"
            Invoke-WebRequest -Uri $XamlUrl -OutFile $XamlPath -UseBasicParsing
            Add-AppxPackage -Path $XamlPath -ErrorAction SilentlyContinue

            Write-Host "[-] Instalando dependencias de runtime (VCLibs)..." -ForegroundColor Gray
            $VCLibsUrl = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
            $VCLibsPath = Join-Path $TempDir "VCLibs.appx"
            Invoke-WebRequest -Uri $VCLibsUrl -OutFile $VCLibsPath -UseBasicParsing
            Add-AppxPackage -Path $VCLibsPath -ErrorAction SilentlyContinue

            Write-Host "[-] Instalando Windows Package Manager (Winget)..." -ForegroundColor Gray
            $WingetUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
            $WingetPath = Join-Path $TempDir "Winget.msixbundle"
            Invoke-WebRequest -Uri $WingetUrl -OutFile $WingetPath -UseBasicParsing
            
            Add-AppxPackage -Path $WingetPath -ErrorAction Stop

            Remove-Item $XamlPath, $VCLibsPath, $WingetPath -Force -ErrorAction SilentlyContinue
            Update-Environment
            Write-Host "[OK] Winget fue instalado e integrado exitosamente." -ForegroundColor Green
        } catch {
            Write-Host "[FALLO] Error crítico al intentar instalar Winget: $_" -ForegroundColor Red
            throw "El sistema no cuenta con Winget y el Bootstrapper falló. No se pueden instalar aplicaciones."
        }
    } else {
        Write-Host "`n[OK] Gestor Winget detectado correctamente." -ForegroundColor Green
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
        $ListadoInstalados = & winget list --id "$WingetId" --exact --accept-source-agreements 2>$null | Out-String
        $YaInstalado = $ListadoInstalados -match [regex]::Escape($WingetId)

        if ($YaInstalado) {
            Write-Host "[-] $AppName ya esta instalado. Verificando actualizacion..." -ForegroundColor Gray
            $WingetArgs = "upgrade --id `"$WingetId`" --silent --exact --accept-package-agreements --accept-source-agreements"
        } else {
            Write-Host "[-] $AppName no instalado. Iniciando despliegue silencioso..." -ForegroundColor Gray
            $WingetArgs = "install --id `"$WingetId`" --silent --exact --accept-package-agreements --accept-source-agreements --architecture x64" } if ($Arguments) { $WingetArgs += " --override `"$Arguments`""
        }

        $Process = Start-Process -FilePath "winget" -ArgumentList $WingetArgs -PassThru -NoNewWindow
        if (-not $Process.WaitForExit(600000)) {
            $Process | Stop-Process -Force -ErrorAction SilentlyContinue
            throw "TIMEOUT: Instalacion excedio 10 minutos."
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
            return [PSCustomObject]@{ app_name = $AppName; estado = $Estado; version_instalada = "Ultima disponible"; tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2); error_mensaje = $null }
        } else {
            throw "Winget Exit Code: $ExitCode"
        }
    } catch {
        $AppSw.Stop()
        Write-Host "[FALLO] Error al instalar ${AppName}: $_" -ForegroundColor Red
        return [PSCustomObject]@{ app_name = $AppName; estado = "FAILED"; version_instalada = "N/A"; tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2); error_mensaje = $_.Exception.Message }
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
        $Release = Invoke-RestMethod -Uri$ApiUrl -UseBasicParsing
        $VersionRemota =$Release.tag_name -replace '^v', ''
        Write-Host "[-] Version publicada: $VersionRemota" -ForegroundColor Gray

        $RutasRegistro = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $Instalado = Get-ItemProperty -Path$RutasRegistro -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$AppName*" } |
            Select-Object -First 1

        if ($Instalado -and$Instalado.DisplayVersion) {
            $VersionLocal =$Instalado.DisplayVersion
            Write-Host "[-] $AppName instalado (version local:$VersionLocal)." -ForegroundColor Gray
            $EsVersionVigente =$false
            try { $EsVersionVigente = [version]$VersionLocal -ge [version]$VersionRemota } 
            catch { $EsVersionVigente = ($VersionLocal -eq$VersionRemota) }
            
            if ($EsVersionVigente) {$AppSw.Stop()
                Write-Host "[OK] $AppName se encuentra en la ultima version." -ForegroundColor Green
                return [PSCustomObject]@{ app_name = $AppName; estado = "YA_ACTUALIZADO"; version_instalada = $VersionLocal; tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2); error_mensaje =$null }
            }
        }

        $Asset =$Release.assets | Where-Object {
            ($_.name -like "*$AssetFilter*" -or $_.name -like "*x64*" -or $_.name -like "*win64*" -or $_.name -like "*64*") -and
            ($_.name -like "*.exe" -or $_.name -like "*.msi") -and
            ($_.name -notlike "*arm*") -and ($_.name -notlike "*mac*") -and ($_.name -notlike "*linux*")
        } | Select-Object -First 1

        if (-not $Asset) {$Asset = $Release.assets \vert{} Where-Object { ($_.name -like "*.exe" -or $_.name -like "*.msi") -and ($_.name -notlike "*arm*") } | Select-Object -First 1
        }
        if (-not $Asset) { throw "No se encontro un asset ejecutable x64." }

        $DownloadUrl = $Asset.browser_download_url$
