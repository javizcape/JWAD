#====================================================================
# SCRIPT DE IMPLEMENTACION MASIVA DE APLICACIONES (Windows x64)
#====================================================================
# Version: 2.2 (Corregida - Septiembre 2026)
# Autor: Arquitectura de Sistemas y Gobernanza Autonoma - Gemini Notebook
# Alojado en: https://javizcape.github.io/JWAD/JWAD.ps1
# Ejecucion:  irm https://javizcape.github.io/JWAD/JWAD.ps1 | iex
#====================================================================

$ErrorActionPreference = "Stop"

# Este script esta disenado para ejecutarse UNICAMENTE via:
#   irm https://javizcape.github.io/JWAD/JWAD.ps1 | iex
# Nunca se ejecuta como archivo local, por lo que $PSCommandPath jamas
# existe y no debe usarse. Si cambias de repositorio o de ruta, actualiza
# esta URL antes de publicar.
$ScriptRemoteUrl = "https://javizcape.github.io/JWAD/JWAD.ps1"

$DesktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
$ReportePath = Join-Path $DesktopPath "Reporte_Despliegue.json"
$TiempoTotalSw = [System.Diagnostics.Stopwatch]::StartNew()

#====================================================================
# CAPA DE PRESENTACION (FRONTEND) - No altera logica de negocio.
# Banner de apertura en ASCII PURO (sin caracteres Unicode de bloque/
# caja): la version anterior usaba glifos de bloque Unicode que, al viajar
# por el pipeline "irm | iex" (descarga remota + interpretacion del
# codigo), pueden llegar a decodificarse con la pagina de codigos
# incorrecta (ANSI/CP1252 en vez de UTF-8) y mostrarse como texto
# corrupto (mojibake). Usando solo caracteres ASCII (\ _ | / =) se
# garantiza que el logo se vea igual de bien en cualquier consola,
# igual que ya ocurre con la firma pequena del cierre.
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
Write-Host "         WINDOWS APP DEPLOYER - v2.2" -ForegroundColor DarkCyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""

# 1. VALIDACION PREVIA Y PRIVILEGIOS DE ADMINISTRADOR
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " INICIANDO ANALISIS DE SISTEMA Y CONTROL DE PRIVILEGIOS" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# Validar Arquitectura x64
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
    Write-Host "[ERROR FATAL] Este script solo es compatible con la arquitectura Windows x64 (AMD64)." -ForegroundColor Red
    return
}
Write-Host "[OK] Arquitectura compatible verificada: x64" -ForegroundColor Green

# Validar que la URL remota fue configurada (requisito para poder re-elevar)
if (-not $ScriptRemoteUrl -or $ScriptRemoteUrl -like "*tuusuario*") {
    Write-Host "[ERROR FATAL] ScriptRemoteUrl no esta configurada. Edita la variable al inicio del script con la URL publica real antes de publicarlo." -ForegroundColor Red
    return
}

# Validar Privilegios de Administrador
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warning "[ADVERTENCIA] El script no se esta ejecutando como Administrador."
    Write-Host "[*] Intentando elevar privilegios (se abrira una nueva ventana elevada)..." -ForegroundColor Yellow
    try {
        # No hay archivo fisico en disco (ejecucion via irm | iex), asi que el
        # proceso elevado vuelve a descargar y ejecutar el script desde la URL remota.
        $Comando = "irm $ScriptRemoteUrl | iex"
        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$Comando`"" -Verb RunAs | Out-Null
    } catch {
        Write-Host "[ERROR FATAL] Se requieren privilegios de Administrador para realizar las instalaciones. $($_.Exception.Message)" -ForegroundColor Red
    }
    # Se usa 'return' (no 'exit') para no cerrar la ventana de PowerShell
    # original del usuario; la instalacion real continua en la ventana elevada.
    return
}
Write-Host "[OK] Privilegios de Administrador confirmados." -ForegroundColor Green

# 2. DEFINICION DE FUNCIONES DE INSTALACION
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
            throw "Winget no esta disponible en este sistema o no se encuentra en el PATH."
        }

        # Paso 1: validar si la aplicacion ya esta instalada ANTES de descargar
        # o instalar nada, para no gastar recursos de forma innecesaria.
        $ListadoInstalados = & winget list --id "$WingetId" --exact --accept-source-agreements 2>$null | Out-String
        $YaInstalado = $ListadoInstalados -match [regex]::Escape($WingetId)

        if ($YaInstalado) {
            # Paso 2: si ya esta instalado, se valida contra la fuente oficial
            # (repositorio de winget) si existe una version mas nueva, en vez
            # de asumir que "ya instalado" es un error.
            Write-Host "[-] $AppName ya esta instalado. Verificando si existe una version mas reciente en la fuente oficial..." -ForegroundColor Gray
            $WingetArgs = "upgrade --id `"$WingetId`" --silent --exact --accept-package-agreements --accept-source-agreements"
        } else {
            Write-Host "[-] $AppName no esta instalado. Se procedera con la descarga e instalacion silenciosa (sin interfaz)." -ForegroundColor Gray
            $WingetArgs = "install --id `"$WingetId`" --silent --exact --accept-package-agreements --accept-source-agreements --architecture x64"
        }
        if ($Arguments) {
            $WingetArgs += " --override `"$Arguments`""
        }

        $Process = Start-Process -FilePath "winget" -ArgumentList $WingetArgs -Wait -NoNewWindow -PassThru
        $ExitCode = $Process.ExitCode
        $AppSw.Stop()

        # Codigos de retorno que representan EXITO (no un error real):
        #   0            : Exito (instalado o actualizado)
        #   3010         : Exito, requiere reinicio
        #   -1978335186  : Ya estaba instalado exactamente en esa version
        #   -1978335189  : APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
        #                  (ya se encuentra en la ultima version disponible)
        $CodigosExito = @(0, 3010, -1978335186, -1978335189)
        if ($CodigosExito -contains $ExitCode) {
            $Estado = "INSTALLED"
            if ($ExitCode -eq -1978335186 -or $ExitCode -eq -1978335189) { $Estado = "YA_ACTUALIZADO" }
            elseif ($ExitCode -eq 3010) { $Estado = "INSTALLED_REINICIO_PENDIENTE" }

            Write-Host "[OK] ${AppName}: $Estado" -ForegroundColor Green
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
    Write-Host "`n[*] Consultando ultima version de $AppName ($Repo) en GitHub (fuente oficial)..." -ForegroundColor Blue
    try {
        $ApiUrl = "https://api.github.com/repos/$Repo/releases/latest"
        # Forzar TLS 1.2 o superior
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $Release = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing
        $VersionRemota = $Release.tag_name -replace '^v', ''
        Write-Host "[-] Version mas reciente publicada: $VersionRemota" -ForegroundColor Gray

        # Paso 1: validar si ya esta instalada la misma version (o una mas
        # reciente) ANTES de descargar nada, para no gastar recursos de forma
        # innecesaria. Se consulta el registro de Windows.
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
            Write-Host "[-] $AppName ya esta instalado (version local: $VersionLocal)." -ForegroundColor Gray
            $EsVersionVigente = $false
            try {
                $EsVersionVigente = [version]$VersionLocal -ge [version]$VersionRemota
            } catch {
                # Si el formato de version no se puede comparar como [version],
                # se compara como texto plano.
                $EsVersionVigente = ($VersionLocal -eq $VersionRemota)
            }
            if ($EsVersionVigente) {
                $AppSw.Stop()
                Write-Host "[OK] $AppName ya se encuentra en la ultima version disponible. No se requiere descarga." -ForegroundColor Green
                return [PSCustomObject]@{
                    app_name = $AppName
                    estado   = "YA_ACTUALIZADO"
                    version_instalada = $VersionLocal
                    tiempo_instalacion_segundos = [Math]::Round($AppSw.Elapsed.TotalSeconds, 2)
                    error_mensaje = $null
                }
            }
            Write-Host "[-] Hay una version mas reciente disponible en el repositorio oficial. Se procedera a actualizar." -ForegroundColor Gray
        } else {
            Write-Host "[-] $AppName no esta instalado. Se procedera con la descarga e instalacion silenciosa (sin interfaz)." -ForegroundColor Gray
        }

        # Filtrar assets compatibles con x64
        $Asset = $Release.assets | Where-Object {
            ($_.name -like "*$AssetFilter*" -or $_.name -like "*x64*" -or $_.name -like "*win64*" -or $_.name -like "*64*") -and
            ($_.name -like "*.exe" -or $_.name -like "*.msi") -and
            ($_.name -notlike "*arm*") -and
            ($_.name -notlike "*mac*") -and
            ($_.name -notlike "*linux*")
        } | Select-Object -First 1

        if (-not $Asset) {
            # Busqueda de respaldo generica
            $Asset = $Release.assets | Where-Object {
                ($_.name -like "*.exe" -or $_.name -like "*.msi") -and
                ($_.name -notlike "*arm*")
            } | Select-Object -First 1
        }

        if (-not $Asset) {
            throw "No se encontro ningun asset ejecutable x64 compatible."
        }

        $DownloadUrl = $Asset.browser_download_url
        $FileName = $Asset.name
        $TempPath = Join-Path $env:TEMP $FileName

        Write-Host "[-] Descargando $FileName..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempPath -UseBasicParsing

        Write-Host "[-] Instalando de forma silenciosa (sin interfaz ni asistente)..." -ForegroundColor Gray
        $ExitCode = 0
        if ($FileName -like "*.msi") {
            # Instalador MSI: los unicos switches validos para instalacion
            # silenciosa son /qn (o /quiet) y /norestart. Cualquier switch
            # adicional propio de instaladores EXE (por ejemplo /S) produce el
            # error 1639 (ERROR_INVALID_COMMAND_LINE), por lo que aqui NO se
            # reenvia el parametro -Arguments recibido.
            $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$TempPath`" /qn /norestart" -Wait -NoNewWindow -PassThru
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

#====================================================================
# CAPA DE PRESENTACION (FRONTEND) - No altera logica de negocio.
# Barra de progreso ASCII simple y visual para seguir el avance global
# del despliegue (complementos + 11 aplicaciones = 14 pasos).
#
# NOTAS DE AJUSTE:
# - Se reemplazan los caracteres de bloque Unicode que se usaban antes
#   por caracteres ASCII puros ('#', '.', '[', ']'), ya que al viajar
#   por el pipeline remoto "irm | iex" podian decodificarse con la
#   pagina de codigos incorrecta y mostrarse como texto corrupto.
# - Se retira el porcentaje por aplicacion: como cada instalacion es
#   una operacion atomica (via winget o msiexec en modo silencioso, sin
#   progreso incremental real), mostrar un "%" por app era enganoso -
#   por ejemplo, marcaba "100%" justo antes de iniciar la ultima
#   instalacion, cuando en realidad esta ni siquiera habia comenzado.
#   En su lugar se muestra el tiempo total transcurrido en segundos
#   (dato real y siempre coherente, tomado del cronometro global).
# - Paleta alineada con el resto del script (nada de magenta): azul
#   claro/oscuro para la estructura, blanco para el dato, y verde para
#   la porcion ya recorrida (mismo verde que usan los mensajes [OK]).
#====================================================================
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

$JWADPasoActual = 0
$JWADPasosTotal = 14

# 3. VERIFICACION E INSTALACION DE COMPLEMENTOS PREVIOS (REQUISITOS)
Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host " INSTALANDO COMPLEMENTOS DE SISTEMA REQUERIDOS" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# Visual C++ Redistributable x64
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Visual C++ Redistributable x64"
$VCRedistResult = Install-AppViaWinget -AppName "Visual C++ Redistributable x64" -WingetId "Microsoft.VCRedist.2015+.x64"

# .NET Framework (validacion, no reinstalacion forzada)
# NOTA TECNICA: en Windows 10/11 el .NET Framework 4.x viene incluido de
# fabrica y se actualiza via Windows Update, no mediante DISM. El nombre de
# caracteristica "NetFX4" usado en la version anterior de este script NO
# existe como feature de DISM, lo cual provocaba el error 0x800f0813. Aqui
# se valida su presencia y version consultando el registro oficial de .NET.
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label ".NET Framework (validacion)"
$NetSw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "[*] Verificando presencia de .NET Framework 4.x..." -ForegroundColor Blue
try {
    $NetRelease = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction Stop).Release
    $NetSw.Stop()
    if ($NetRelease -ge 528040) {
        Write-Host "[OK] .NET Framework 4.8 (o superior) ya esta instalado (Release: $NetRelease)." -ForegroundColor Green
        $NetResult = [PSCustomObject]@{
            app_name = ".NET Framework"
            estado   = "YA_ACTUALIZADO"
            version_instalada = "Release $NetRelease"
            tiempo_instalacion_segundos = [Math]::Round($NetSw.Elapsed.TotalSeconds, 2)
            error_mensaje = $null
        }
    } else {
        Write-Host "[AVISO] Version de .NET Framework antigua detectada (Release: $NetRelease). Se recomienda actualizar via Windows Update." -ForegroundColor Yellow
        $NetResult = [PSCustomObject]@{
            app_name = ".NET Framework"
            estado   = "DESACTUALIZADO"
            version_instalada = "Release $NetRelease"
            tiempo_instalacion_segundos = [Math]::Round($NetSw.Elapsed.TotalSeconds, 2)
            error_mensaje = $null
        }
    }
} catch {
    $NetSw.Stop()
    Write-Host "[FALLO] No se pudo verificar .NET Framework: $_" -ForegroundColor Red
    $NetResult = [PSCustomObject]@{
        app_name = ".NET Framework"
        estado   = "FAILED"
        version_instalada = "N/A"
        tiempo_instalacion_segundos = [Math]::Round($NetSw.Elapsed.TotalSeconds, 2)
        error_mensaje = $_.Exception.Message
    }
}

# Java Runtime Environment (JRE) x64
# NOTA: Oracle discontinuo la distribucion publica de "Oracle.JRE" en el
# repositorio de winget (por eso fallaba con "paquete no encontrado"). El
# reemplazo libre y con soporte activo es Eclipse Temurin JRE (OpenJDK).
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Java Runtime Environment (JRE) x64"
$JavaResult = Install-AppViaWinget -AppName "Java Runtime Environment" -WingetId "EclipseAdoptium.Temurin.21.JRE"

# 4. INSTALACION DE LAS 11 APLICACIONES PRINCIPALES
Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host " INICIANDO IMPLEMENTACION DE LAS 11 APLICACIONES PRINCIPALES" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

$ResultadosList = [System.Collections.Generic.List[PSCustomObject]]::new()

# Agregar complementos de sistema a la lista de reportes
$ResultadosList.Add($VCRedistResult)
$ResultadosList.Add($NetResult)
$ResultadosList.Add($JavaResult)

# App 1: 7-Zip (Winget)
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "7-Zip"
$ResultadosList.Add((Install-AppViaWinget -AppName "7-Zip" -WingetId "7zip.7zip"))

# App 2: Bulk Crap Uninstaller (Winget)
# NOTA: el ID correcto en el repositorio de winget es "Klocman.BulkCrapUninstaller"
# (el usado antes, "BCUninstaller.BulkCrapUninstaller", no existe y causaba el
# error "paquete no encontrado"). El instalador es Inno Setup: los switches
# silenciosos correctos son /VERYSILENT /SUPPRESSMSGBOXES /NORESTART.
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Bulk Crap Uninstaller"
$ResultadosList.Add((Install-AppViaWinget -AppName "Bulk Crap Uninstaller" -WingetId "Klocman.BulkCrapUninstaller" -Arguments "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"))

# App 3: SumatraPDF (Winget)
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "SumatraPDF"
$ResultadosList.Add((Install-AppViaWinget -AppName "SumatraPDF" -WingetId "SumatraPDF.SumatraPDF"))

# App 4: AB Download Manager (GitHub - Descarga Directa)
# NOTA: el instalador es NSIS; el switch silencioso correcto es /S (no /SILENT,
# que no es reconocido por NSIS y provocaba el Exit Code 1).
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "AB Download Manager"
$ResultadosList.Add((Install-AppViaDirectUrl -AppName "AB Download Manager" -Repo "amir1376/ab-download-manager" -AssetFilter "Setup" -Arguments "/S"))

# App 5: WinRAR x64 (ES) (Winget)
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "WinRAR x64"
$ResultadosList.Add((Install-AppViaWinget -AppName "WinRAR x64" -WingetId "RARLab.WinRAR" -Arguments "/S"))

# App 6: VLC Media Player (Winget)
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "VLC Media Player"
$ResultadosList.Add((Install-AppViaWinget -AppName "VLC Media Player" -WingetId "VideoLAN.VLC" -Arguments "/S"))

# App 7: Google Chrome (Winget)
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Google Chrome"
$ResultadosList.Add((Install-AppViaWinget -AppName "Google Chrome" -WingetId "Google.Chrome" -Arguments "/silent /install"))

# App 8: Mozilla Firefox (Winget)
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Mozilla Firefox"
$ResultadosList.Add((Install-AppViaWinget -AppName "Mozilla Firefox" -WingetId "Mozilla.Firefox" -Arguments "-ms"))

# App 9: Mullvad Browser (Winget)
# NOTA: el ID correcto en el repositorio de winget es "MullvadVPN.MullvadBrowser"
# (el usado antes, "Mullvad.MullvadBrowser", no existe y causaba el error
# "paquete no encontrado"). El instalador es NSIS, switch silencioso /S.
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Mullvad Browser"
$ResultadosList.Add((Install-AppViaWinget -AppName "Mullvad Browser" -WingetId "MullvadVPN.MullvadBrowser" -Arguments "/S"))

# App 10: Microsoft Edge para Empresas (Winget)
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "Microsoft Edge"
$ResultadosList.Add((Install-AppViaWinget -AppName "Microsoft Edge" -WingetId "Microsoft.Edge" -Arguments "/silent"))

# App 11: FlyPhotos (GitHub - Descarga Directa)
# NOTA: el instalador es MSI; no se envia -Arguments porque el switch previo
# (/S) no es valido para msiexec y provocaba el Exit Code 1639. La funcion ya
# aplica /qn /norestart de forma nativa para instaladores MSI.
$JWADPasoActual++
Show-JWADProgressBar -Current $JWADPasoActual -Total $JWADPasosTotal -Label "FlyPhotos"
$ResultadosList.Add((Install-AppViaDirectUrl -AppName "FlyPhotos" -Repo "riyasy/FlyPhotos" -AssetFilter "Setup"))

# 5. RECOPILACION DE TELEMETRIA DEL HARDWARE Y DEL SISTEMA
Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host " RECOPILANDO TELEMETRIA Y ESPECIFICACIONES DEL SISTEMA" -ForegroundColor Cyan
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

# Diagnosticos de Temperatura
$LecturasTemp = [System.Collections.Generic.List[PSCustomObject]]::new()
$TempFinal = $null

# Metodo 1: CIM_ThermalZone
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

# Metodo 2: WMI_MSAcpi
try {
    $WmiZones = Get-CimInstance -Namespace "root/wmi" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction Stop
    if ($WmiZones) {
        # La lectura es en decimas de Kelvin (ej: 3002 = 300.2 Kelvin)
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

# Detener el cronometro total
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

# 7. VISUALIZACION DEL REPORTE FINAL EN CONSOLA
Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host " REPORTE FINAL DE DESPLIEGUE Y TELEMETRIA" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green

Write-Host "[-] Fecha y Hora: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")"
Write-Host "[-] Equipo: $Fabricante $Modelo"
Write-Host "[-] Procesador: $Procesador"
Write-Host "[-] Memoria RAM: $RAMTotalGB GB (En uso: $RAMUsoPct %)"
Write-Host "[-] Disco (C:): $DiscoTotalGB GB (En uso: $DiscoUsoPct %)"
if ($null -ne $TempFinal) {
    Write-Host "[-] Temperatura CPU: $TempFinal C" -ForegroundColor Yellow
} else {
    Write-Host "[-] Temperatura CPU: No disponible (Hardware bloqueado o no soportado)" -ForegroundColor Gray
}
Write-Host "[-] Tiempo Total de Ejecucion: $TiempoTotalSegundos segundos" -ForegroundColor Cyan
Write-Host "[-] Archivo de Reporte Creado en: $ReportePath" -ForegroundColor Green

Write-Host "`n[-] Estado de las Instalaciones:" -ForegroundColor Gray
foreach ($App in $ResultadosList) {
    $Color = "Green"
    if ($App.estado -eq "FAILED") { $Color = "Red" }
    elseif ($App.estado -eq "DESACTUALIZADO") { $Color = "Yellow" }
    Write-Host "    * [$($App.estado)] $($App.app_name) - Version: $($App.version_instalada) ($($App.tiempo_instalacion_segundos)s)" -ForegroundColor $Color
}
Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host " Proceso de automatizacion finalizado con exito." -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green

#====================================================================
# CAPA DE PRESENTACION (FRONTEND) - No altera logica de negocio.
# Firma ASCII de cierre, version reducida del banner de apertura.
#====================================================================
$JWADBannerPequeno = @(
    '    ___      ___   ___  ',
    ' _ | \ \    / /_\ |   \ ',
    '| || |\ \/\/ / _ \| |) |',
    ' \__/  \_/\_/_/ \_\___/ '
)

Write-Host ""
foreach ($JWADLinea in $JWADBannerPequeno) {
    Write-Host "  $JWADLinea" -ForegroundColor DarkGray
}
Write-Host "  javizcape.github.io/JWAD" -ForegroundColor DarkGray
Write-Host ""
