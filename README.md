<div align="center">

# Windows App Deployer (WAD)

Script de código abierto para la implementación masiva, silenciosa y automatizada de software esencial en sistemas Windows x64, con reportes de telemetría y diagnósticos de hardware.

</div>

---

## 🚀 Ejecución Rápida (Recomendado)

### Método 1 - PowerShell ❤️

1. Haz clic en el **Menú Inicio**, escribe `PowerShell` y ábrelo (el script solicitará permisos de Administrador automáticamente si es necesario).

2. Copia y pega el código a continuación y presiona **Enter**.

    * Para **Windows 10 y 11 (x64)**:
      ```powershell
      irm [https://javizcape.github.io/.ps1/install-apps.ps1](https://javizcape.github.io/.ps1/install-apps.ps1) | iex
      ```

    * Si el comando anterior es bloqueado por tu red o proveedor de internet (ISP/DNS), intenta esta alternativa:
      ```powershell
      iex (curl.exe -s [https://javizcape.github.io/.ps1/install-apps.ps1](https://javizcape.github.io/.ps1/install-apps.ps1) | Out-String)
      ```

---

## 🛠️ Características Principales

* **Auto-elevación de Privilegios (UAC):** Detecta automáticamente si el usuario estándar requiere permisos de Administrador y re-invoca la sesión remota sin interrumpir el flujo.
* **Filtro Estricto de Arquitectura:** Validación en tiempo real para asegurar la ejecución exclusiva en entornos compatibles de 64 bits (`AMD64`).
* **Despliegue Híbrido Silencioso:** 
  * Prioriza la instalación nativa, limpia y sin interrupciones desde los repositorios oficiales de Microsoft mediante **Winget**.
  * Utiliza un sistema de extracción avanzado vía **GitHub API** para aplicaciones de código abierto que no cuentan con instaladores empaquetados oficiales (ej. *FlyPhotos*, *AB Download Manager*).
* **Gestión de Errores Integrada:** Captura códigos de salida de Windows (Exit Codes como `0` o `3010`) para validar que cada instalación fue exitosa antes de continuar.

---

## 📦 Software Incluido

El script automatiza la instalación de las siguientes herramientas esenciales, asegurando que se descargue la última versión estable de cada una:

| Categoría | Aplicaciones |
| :--- | :--- |
| **Requisitos de Sistema** | Visual C++ Redistributable 2015+, .NET Framework (Activación DISM), Java JRE x64 |
| **Herramientas de Sistema** | 7-Zip, Bulk Crap Uninstaller |
| **Ofimática y Multimedia** | SumatraPDF, VLC Media Player, FlyPhotos |
| **Navegadores Web** | Google Chrome, Mozilla Firefox, Mullvad Browser, Microsoft Edge |
| **Utilidades de Red** | WinRAR x64, AB Download Manager |

---

## 📊 Reporte de Telemetría JSON

Al finalizar todo el proceso de instalación, el script genera un archivo `Reporte_Despliegue.json` directamente en el Escritorio. Este documento incluye datos cruciales para la auditoría del equipo:

* **Especificaciones del Hardware:** Fabricante, modelo, procesador y arquitectura.
* **Métricas de Rendimiento:** Capacidad total y porcentaje de uso actual de la memoria RAM y el almacenamiento principal (Disco C:).
* **Diagnósticos Térmicos:** Mediciones de temperatura de la CPU obtenidas directamente de los sensores de la placa base (vía WMI/CIM).
* **Auditoría de Instalación:** Tiempos individuales de instalación en segundos por cada aplicación y su estado final (Éxito/Fallo).

---

## 📄 Licencia

Este proyecto es de código abierto y se distribuye bajo la licencia **MIT**. Eres libre de auditar el código fuente, modificarlo, redistribuirlo y adaptarlo a tus propios flujos de trabajo o necesidades de administración de sistemas.
