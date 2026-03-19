# ============================================================
#   ORQUESTADOR - PRACTICA 7 (WINDOWS)
#   Soporta origen WEB o FTP (navegacion dinamica)
#   SSL/TLS: IIS :443 | Apache :4443 | Nginx :8443 | IIS-FTP :21
#   Verificacion SHA256 para instaladores descargados via FTP
#
#   Ejecutar como Administrador:
#   powershell -ExecutionPolicy Bypass -File orquestador_windows_p7.ps1
# ============================================================

# ============================================================
#   CONFIGURACION - CAMBIA ESTAS IPs SEGUN TU ENTORNO
# ============================================================
$MI_IP      = "192.168.137.240"    # IP principal Windows (VMnet8 NAT)
# Detectar IP del servidor FTP dinamicamente
# Se usa la IP que NO sea NAT (192.168.137.x) ni loopback
$FTP_SERVER = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch "^127\." -and
                   $_.IPAddress -notmatch "^192\.168\.137\." -and
                   $_.IPAddress -ne "0.0.0.0" } |
    Select-Object -First 1).IPAddress
if (-not $FTP_SERVER) { $FTP_SERVER = "127.0.0.1" }
$FTP_USER   = "usuario"
$FTP_PASS   = "1234"
$FTP_PORT   = 21

# ============================================================
#   VARIABLES GLOBALES
# ============================================================
$DOMINIO  = "reprobados.com"
$CERT_DIR = "C:\SSL\reprobados"
$LOG_FILE = "C:\Logs\orquestador.log"
$RESUMEN  = @()
$SERVICIO = ""
$BASE_FTP = "ftp://$FTP_SERVER"

# Directorios de trabajo
foreach ($d in @($CERT_DIR, "C:\Logs", "C:\Temp", "C:\opt")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
if (-not (Test-Path $LOG_FILE)) { New-Item -ItemType File -Force -Path $LOG_FILE | Out-Null }

# Verificar privilegios de administrador
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $esAdmin) {
    Write-Host "ERROR: Debes ejecutar este script como Administrador." -ForegroundColor Red
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================
#   FUNCIONES UTILITARIAS
# ============================================================

function Log {
    param([string]$M, [string]$C = "White")
    Write-Host $M -ForegroundColor $C
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $M" | Out-File -Append -FilePath $LOG_FILE -Encoding UTF8
}

function SinBOM {
    param([string]$P, [string]$C)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($P, $C, $enc)
}

function BuscarExe {
    param([string]$N)
    $rutas = @("C:\opt\","C:\Apache24\","C:\tools\","C:\ProgramData\chocolatey\lib\",
               "$env:APPDATA\","C:\Program Files\","C:\Program Files (x86)\")
    foreach ($r in $rutas) {
        if (Test-Path $r) {
            $found = Get-ChildItem $r -Recurse -Filter $N -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found }
        }
    }
    return $null
}

# ============================================================
#   DESCARGAR DESDE WEB (3 metodos)
# ============================================================
function Bajar {
    param([string]$Url, [string]$Dest)
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 1: curl
    Log "  [curl] $Url" Cyan
    & curl.exe -L --connect-timeout 30 --max-time 600 --progress-bar -o "$Dest" "$Url" 2>&1
    if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) {
        Log "  OK curl: $([math]::Round((Get-Item $Dest).Length/1MB,1)) MB" Green
        return $true
    }
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 2: Invoke-WebRequest
    Log "  [Invoke-WebRequest] $Url" Cyan
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) {
            Log "  OK IWR: $([math]::Round((Get-Item $Dest).Length/1MB,1)) MB" Green
            return $true
        }
    } catch { Log "  Fallo IWR: $_" Yellow }
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 3: WebClient
    Log "  [WebClient] $Url" Cyan
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $Dest)
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) {
            Log "  OK WebClient: $([math]::Round((Get-Item $Dest).Length/1MB,1)) MB" Green
            return $true
        }
    } catch { Log "  Fallo WebClient: $_" Yellow }
    Remove-Item $Dest -ErrorAction SilentlyContinue
    return $false
}

# ============================================================
#   CLIENTE FTP DINAMICO - NAVEGAR ESTRUCTURA REMOTA
# ============================================================

function FTP_ListarDirectorio {
    param([string]$RutaFTP)
    # Usa curl para listar el directorio FTP
    $resultado = & curl.exe --silent --ftp-ssl --insecure --ftp-pasv `
        -u "${FTP_USER}:${FTP_PASS}" `
        --list-only `
        "$BASE_FTP$RutaFTP/" 2>&1
    # Filtrar lineas vacias y el archivo .keep
    return ($resultado | Where-Object { $_ -and $_ -notmatch "^\.keep$" -and $_ -notmatch "^\s*$" })
}

function FTP_DescargarArchivo {
    param([string]$RutaFTP, [string]$DestLocal)
    Remove-Item $DestLocal -ErrorAction SilentlyContinue
    Log "  Descargando desde FTP: $RutaFTP" Cyan
    & curl.exe --silent --show-error --ftp-ssl --insecure --ftp-pasv `
        -u "${FTP_USER}:${FTP_PASS}" `
        -o "$DestLocal" `
        "$BASE_FTP$RutaFTP" 2>&1
    if ((Test-Path $DestLocal) -and (Get-Item $DestLocal).Length -gt 1000) {
        Log "  OK: $([math]::Round((Get-Item $DestLocal).Length/1MB,2)) MB descargados." Green
        return $true
    }
    Log "  ERROR: Archivo no descargado o vacio." Red
    return $false
}

function FTP_DescargarDesdeRepositorio {
    param([string]$OS)   # "Windows" o "Linux"

    Log "" White
    Log "========================================" Cyan
    Log "  CLIENTE FTP DINAMICO - reprobados.com " Cyan
    Log "========================================" Cyan
    Log "  Servidor: $FTP_SERVER" White
    Log "  OS detectado: $OS" White
    Log "" White

    # Verificar conexion FTP
    Log "Verificando conexion FTP..." Cyan
    $test = & curl.exe --silent --ftp-ssl --insecure --connect-timeout 10 `
        -u "${FTP_USER}:${FTP_PASS}" "$BASE_FTP/" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log "ERROR: No se pudo conectar al FTP $FTP_SERVER" Red
        Log "  Asegurate que vsftpd/FileZilla este corriendo en $FTP_SERVER" Yellow
        return $null
    }
    Log "OK: FTP conectado." Green

    # NIVEL 1: listar /http/[OS]/
    $rutaOS = "/http/$OS"
    Log "" White
    Log "Carpetas disponibles en ${rutaOS}:" Cyan
    $servicios = FTP_ListarDirectorio $rutaOS
    if (-not $servicios) {
        Log "ERROR: No se encontraron carpetas en $rutaOS" Red
        return $null
    }

    $i = 1
    $mapaServicios = @{}
    foreach ($s in $servicios) {
        Write-Host "  $i) $s" -ForegroundColor White
        $mapaServicios[$i.ToString()] = $s
        $i++
    }
    Write-Host ""
    $eleccionSvc = Read-Host "  Selecciona el servicio (numero)"
    if (-not $mapaServicios.ContainsKey($eleccionSvc)) {
        Log "Seleccion invalida." Red
        return $null
    }
    $svcElegido = $mapaServicios[$eleccionSvc]
    $rutaSvc = "$rutaOS/$svcElegido"

    # NIVEL 2: listar archivos en /http/[OS]/[Servicio]/
    Log "" White
    Log "Archivos disponibles en ${rutaSvc}:" Cyan
    $archivos = FTP_ListarDirectorio $rutaSvc
    # Solo mostrar binarios (no .sha256)
    $binarios = $archivos | Where-Object { $_ -notmatch "\.sha256$" -and $_ -notmatch "\.md5$" }

    if (-not $binarios) {
        Log "ERROR: No se encontraron instaladores en $rutaSvc" Red
        return $null
    }

    $j = 1
    $mapaArchivos = @{}
    foreach ($a in $binarios) {
        Write-Host "  $j) $a" -ForegroundColor White
        $mapaArchivos[$j.ToString()] = $a
        $j++
    }
    Write-Host ""
    $eleccionArch = Read-Host "  Selecciona el archivo a descargar (numero)"
    if (-not $mapaArchivos.ContainsKey($eleccionArch)) {
        Log "Seleccion invalida." Red
        return $null
    }
    $archivoElegido = $mapaArchivos[$eleccionArch]
    $rutaArchivo = "$rutaSvc/$archivoElegido"
    $destLocal   = "C:\Temp\$archivoElegido"
    $destHash    = "C:\Temp\$archivoElegido.sha256"

    # Descargar el binario
    if (-not (FTP_DescargarArchivo $rutaArchivo $destLocal)) {
        return $null
    }

    # ============================
    # VERIFICACION SHA256
    # ============================
    Log "" White
    Log "Verificando integridad SHA256..." Cyan
    $rutaHash = "$rutaArchivo.sha256"
    $hashOK = $false

    if (FTP_DescargarArchivo $rutaHash $destHash) {
        try {
            $hashEsperado = (Get-Content $destHash -Raw).Trim().Split(" ")[0].ToLower()
            $hashReal     = (Get-FileHash -Algorithm SHA256 -Path $destLocal).Hash.ToLower()
            if ($hashReal -eq $hashEsperado) {
                Log "OK: SHA256 verificado correctamente." Green
                Log "  Esperado : $hashEsperado" White
                Log "  Calculado: $hashReal" White
                $script:RESUMEN += "OK Hash SHA256: $archivoElegido"
                $hashOK = $true
            } else {
                Log "ERROR: Hash SHA256 NO coincide. Archivo posiblemente corrompido." Red
                Log "  Esperado : $hashEsperado" Red
                Log "  Calculado: $hashReal" Red
                $script:RESUMEN += "FALLO Hash SHA256: $archivoElegido"
                $continuar = Read-Host "  Deseas continuar de todas formas? [S/N]"
                if ($continuar -notmatch "^[sSyY]") { return $null }
            }
        } catch {
            Log "AVISO: No se pudo verificar hash: $_" Yellow
            $hashOK = $true  # Continuar si no hay hash disponible
        }
    } else {
        Log "AVISO: No se encontro archivo .sha256 en FTP. Saltando verificacion." Yellow
        $script:RESUMEN += "AVISO: Sin hash para $archivoElegido"
        $hashOK = $true
    }

    return @{
        Archivo  = $destLocal
        Servicio = $svcElegido
        HashOK   = $hashOK
    }
}

# ============================================================
#   INSTALACION DESDE FTP (manual/silenciosa)
# ============================================================
function InstalarDesdeFTP {
    param([string]$Archivo, [string]$Svc)
    Log "" White
    Log "Instalando $Svc desde: $Archivo" Cyan

    switch -Wildcard ($Archivo) {
        "*.zip" {
            Log "  Extrayendo ZIP en C:\opt\" Cyan
            try {
                Expand-Archive -Path $Archivo -DestinationPath "C:\opt\" -Force
                Log "  OK: Extraido en C:\opt\" Green
                $script:RESUMEN += "OK Instalacion FTP: $Svc (zip)"
            } catch { Log "  ERROR extrayendo: $_" Red }
        }
        "*.msi" {
            Log "  Instalando MSI silenciosamente..." Cyan
            $args = "/i `"$Archivo`" /quiet /norestart /log C:\Logs\install_$Svc.log"
            Start-Process msiexec.exe -ArgumentList $args -Wait -NoNewWindow
            Log "  OK: MSI instalado." Green
            $script:RESUMEN += "OK Instalacion FTP: $Svc (msi)"
        }
        "*.exe" {
            Log "  Ejecutando instalador silencioso..." Cyan
            Start-Process $Archivo -ArgumentList "/S /silent /quiet" -Wait -NoNewWindow
            Log "  OK: EXE instalado." Green
            $script:RESUMEN += "OK Instalacion FTP: $Svc (exe)"
        }
        default {
            Log "  AVISO: Tipo de archivo no reconocido para instalacion automatica." Yellow
            Log "  Archivo disponible en: $Archivo" White
        }
    }
}

# ============================================================
#   INSTALAR DESDE WEB
# ============================================================
function ObtenerApache {
    $exe = BuscarExe "httpd.exe"
    if ($exe) { Log "OK: Apache ya instalado en $($exe.FullName)" Green; return $exe.FullName }

    Log "Descargando Apache desde internet..." Cyan
    $dest = "C:\Temp\apache_win.zip"

    # Instalar via Chocolatey (mas confiable que descargar ZIP)
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $choco) {
        Log "  Instalando Chocolatey..." Cyan
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $chocoScript = (New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1")
            Invoke-Expression $chocoScript
            $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
            $choco = Get-Command choco -ErrorAction SilentlyContinue
        } catch { Log "  Fallo Chocolatey: $_" Yellow }
    }

    if ($choco) {
        Log "  Instalando Apache via Chocolatey..." Cyan
        & choco install apache-httpd --yes --no-progress --force 2>&1 | ForEach-Object { Write-Host "  $_" }
        # Chocolatey puede instalarlo en AppData - buscarlo y copiarlo a C:\opt\Apache24
        $exe2 = BuscarExe "httpd.exe"
        if ($exe2) {
            $srcDir = Split-Path (Split-Path $exe2.FullName)
            $dstDir = "C:\opt\Apache24"
            if ($srcDir -ne $dstDir) {
                Log "  Copiando Apache de $srcDir a $dstDir ..." Cyan
                if (Test-Path $dstDir) { Remove-Item $dstDir -Recurse -Force -ErrorAction SilentlyContinue }
                Copy-Item $srcDir $dstDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            $httpd = "$dstDir\bin\httpd.exe"
            if (-not (Test-Path $httpd)) { $httpd = $exe2.FullName }
            # Detener el servicio Apache instalado por choco (usa puerto 443, lo necesitamos en 4443)
            & sc.exe stop Apache 2>$null | Out-Null
            & sc.exe delete Apache 2>$null | Out-Null
            Start-Sleep -Seconds 2
            Log "OK: Apache listo en $httpd" Green
            return $httpd
        }
    }

    # Fallback: descargar ZIP desde GitHub mirror
    $urls = @(
        "https://github.com/thebugfix/ApacheWindowsBuild/releases/latest/download/Apache24.zip",
        "https://sourceforge.net/projects/apache-httpd-win64/files/latest/download",
        "https://downloads.apache.org/httpd/binaries/win32/"
    )
    $ok = $false
    foreach ($url in $urls) {
        Log "  Intentando ZIP: $url" Cyan
        Remove-Item $dest -ErrorAction SilentlyContinue
        & curl.exe -L --insecure -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
            --connect-timeout 30 --max-time 600 --retry 2 -o "$dest" "$url" 2>&1 | Out-Null
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 500000) {
            Log "  OK: $([math]::Round((Get-Item $dest).Length/1MB,1)) MB" Green
            $ok = $true; break
        }
        Remove-Item $dest -ErrorAction SilentlyContinue
    }

    if ($ok) {
        try { Expand-Archive -Path $dest -DestinationPath "C:\opt\" -Force -ErrorAction Stop }
        catch { Log "ERROR extrayendo Apache: $_" Red; return $null }
    } else {
        Log "ERROR: No se pudo obtener Apache por ninguna via." Red
        return $null
    }

    $exe = BuscarExe "httpd.exe"
    if ($exe) { Log "OK: Apache en $($exe.FullName)" Green; return $exe.FullName }
    Log "ERROR: httpd.exe no encontrado." Red; return $null
}

function ObtenerNginx {
    $exe = BuscarExe "nginx.exe"
    if ($exe) { Log "OK: Nginx ya instalado en $($exe.FullName)" Green; return $exe.FullName }

    Log "Descargando Nginx desde internet..." Cyan
    $dest = "C:\Temp\nginx_win.zip"

    # Nginx.org permite descarga directa sin problemas de redirect
    $urls = @(
        "https://nginx.org/download/nginx-1.26.2.zip",
        "https://nginx.org/download/nginx-1.26.1.zip",
        "https://nginx.org/download/nginx-1.24.0.zip",
        "https://nginx.org/download/nginx-1.22.1.zip"
    )
    $ok = $false
    foreach ($url in $urls) {
        Log "  Intentando: $url" Cyan
        Remove-Item $dest -ErrorAction SilentlyContinue
        & curl.exe -L --insecure -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
            --connect-timeout 30 --max-time 300 --retry 3 -o "$dest" "$url" 2>&1 | Out-Null
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 500000) {
            Log "  OK curl: $([math]::Round((Get-Item $dest).Length/1MB,1)) MB" Green
            $ok = $true; break
        }
        Remove-Item $dest -ErrorAction SilentlyContinue
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            $wc.DownloadFile($url, $dest)
            if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 500000) {
                Log "  OK WebClient: $([math]::Round((Get-Item $dest).Length/1MB,1)) MB" Green
                $ok = $true; break
            }
        } catch { }
        Remove-Item $dest -ErrorAction SilentlyContinue
    }

    # Fallback: Chocolatey
    if (-not $ok) {
        $choco = Get-Command choco -ErrorAction SilentlyContinue
        if ($choco) {
            Log "  Instalando Nginx via Chocolatey..." Cyan
            & choco install nginx --yes --no-progress --force 2>&1 | ForEach-Object { Write-Host "  $_" }
            $exe2 = BuscarExe "nginx.exe"
            if ($exe2) { Log "OK: Nginx via Chocolatey en $($exe2.FullName)" Green; return $exe2.FullName }
        }
    }

    if (-not $ok) { Log "ERROR: No se pudo obtener Nginx." Red; return $null }
    try { Expand-Archive -Path $dest -DestinationPath "C:\opt\" -Force -ErrorAction Stop }
    catch { Log "ERROR extrayendo Nginx: $_" Red; return $null }

    $exe = BuscarExe "nginx.exe"
    if ($exe) { Log "OK: Nginx en $($exe.FullName)" Green; return $exe.FullName }
    Log "ERROR: nginx.exe no encontrado tras extraccion." Red; return $null
}

function InstFeat {
    param([string]$F)
    try {
        Install-WindowsFeature -Name $F -IncludeManagementTools -ErrorAction Stop | Out-Null
        Log "OK: $F habilitado." Green; return $true
    } catch {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName $F -NoRestart -ErrorAction Stop | Out-Null
            Log "OK: $F habilitado." Green; return $true
        } catch { Log "AVISO: $F no habilitado: $_" Yellow; return $false }
    }
}

function InstWeb {
    Log "Instalando $SERVICIO desde WEB..." Cyan
    switch ($SERVICIO) {
        "IIS" {
            InstFeat "Web-Server"
            InstFeat "Web-Common-Http"
            InstFeat "Web-Static-Content"
            InstFeat "Web-Default-Doc"
            InstFeat "Web-Http-Errors"
            & iisreset /start 2>$null
            Set-Service W3SVC -StartupType Automatic -ErrorAction SilentlyContinue
        }
        "Apache" { ObtenerApache | Out-Null }
        "Nginx"  { ObtenerNginx  | Out-Null }
        "FTP" {
            InstFeat "Web-Ftp-Server"
            InstFeat "Web-Ftp-Service"
            InstFeat "Web-Ftp-Ext"
            & iisreset /start 2>$null
        }
    }
    $script:RESUMEN += "OK Instalacion WEB: $SERVICIO"
}

# ============================================================
#   PAGINA WEB - HTTP (muestra "No seguro")
# ============================================================
function PaginaHTTP {
    param([string]$P, [string]$S, [string]$Port)
    $h = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>reprobados.com - $S (HTTP)</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Orbitron:wght@400;700&display=swap');
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #0d0d0d;
      color: #e0e0e0;
      font-family: 'Share Tech Mono', monospace;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
    }
    .warning-bar {
      background: #ff4444;
      color: white;
      width: 100%;
      text-align: center;
      padding: 12px;
      font-size: 14px;
      letter-spacing: 2px;
      font-weight: bold;
      position: fixed;
      top: 0;
    }
    .lock-icon { font-size: 18px; margin-right: 8px; }
    .container {
      background: #1a1a1a;
      border: 1px solid #333;
      border-top: 4px solid #ff4444;
      padding: 40px 50px;
      border-radius: 4px;
      text-align: center;
      max-width: 600px;
      margin-top: 60px;
    }
    h1 {
      font-family: 'Orbitron', monospace;
      color: #ff4444;
      font-size: 2em;
      margin-bottom: 8px;
      letter-spacing: 3px;
    }
    .subtitle { color: #888; font-size: 12px; letter-spacing: 4px; margin-bottom: 30px; }
    .badge {
      display: inline-block;
      background: #ff444422;
      border: 1px solid #ff4444;
      color: #ff4444;
      padding: 8px 20px;
      border-radius: 2px;
      font-size: 13px;
      letter-spacing: 2px;
      margin-bottom: 25px;
    }
    .info-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 15px;
      margin-top: 20px;
    }
    .info-item {
      background: #111;
      border: 1px solid #2a2a2a;
      padding: 15px;
      border-radius: 2px;
      text-align: left;
    }
    .info-label { color: #555; font-size: 10px; letter-spacing: 3px; }
    .info-value { color: #00ff88; font-size: 14px; margin-top: 4px; }
    .http-warning { color: #ff6666; }
    .footer { margin-top: 30px; color: #444; font-size: 11px; }
  </style>
</head>
<body>
  <div class="warning-bar">
    <span class="lock-icon">&#x26A0;</span>
    NO ES SEGURO - La conexion no esta cifrada (HTTP)
  </div>
  <div class="container">
    <h1>reprobados.com</h1>
    <div class="subtitle">PRACTICA 7 - INFRAESTRUCTURA DE DESPLIEGUE</div>
    <div class="badge">&#x1F513; CONEXION NO CIFRADA</div>
    <div class="info-grid">
      <div class="info-item">
        <div class="info-label">SERVIDOR</div>
        <div class="info-value">$S</div>
      </div>
      <div class="info-item">
        <div class="info-label">PROTOCOLO</div>
        <div class="info-value http-warning">HTTP (sin cifrar)</div>
      </div>
      <div class="info-item">
        <div class="info-label">PUERTO</div>
        <div class="info-value">$Port</div>
      </div>
      <div class="info-item">
        <div class="info-label">IP SERVIDOR</div>
        <div class="info-value">$MI_IP</div>
      </div>
    </div>
    <div class="footer">Este sitio no tiene certificado SSL activo</div>
  </div>
</body>
</html>
"@
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($P, $h, $enc)
}

# ============================================================
#   PAGINA WEB - HTTPS (muestra dominio y SSL activo)
# ============================================================
function PaginaHTTPS {
    param([string]$P, [string]$S, [string]$Port)
    $html  = "<!DOCTYPE html><html><head><meta charset='UTF-8'><title>reprobados.com</title>"
    $html += "<style>body{font-family:Arial,sans-serif;background:#1a1a2e;color:white;text-align:center;margin-top:80px}"
    $html += "h1{color:#00d4ff;font-size:2.5em}.box{background:#16213e;padding:30px 50px;border-radius:8px;display:inline-block;margin-top:30px}"
    $html += ".ok{color:#00ff88;font-size:1.2em;font-weight:bold}p{color:#a8b2d8;margin:10px 0}strong{color:white}</style></head>"
    $html += "<body><h1>reprobados.com</h1><div class='box'>"
    $html += "<p class='ok'>HTTPS Activo</p>"
    $html += "<p>Servidor: <strong>$S</strong></p>"
    $html += "<p>Puerto: <strong>$Port</strong></p>"
    $html += "<p>Practica 7 - Infraestructura de Despliegue</p>"
    $html += "</div></body></html>"
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($P, $html, $enc)
}
# ============================================================
#   GENERAR CERTIFICADO AUTOFIRMADO
# ============================================================
function GenCert {
    param([string]$Svc)
    Log "Generando certificado autofirmado para $Svc..." Cyan

    # Eliminar certificados anteriores del mismo servicio
    Get-ChildItem "Cert:\LocalMachine\My" |
        Where-Object { $_.FriendlyName -eq "reprobados-$Svc" } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    try {
        $cert = New-SelfSignedCertificate `
            -DnsName $DOMINIO, "www.$DOMINIO", $MI_IP `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddDays(365) `
            -FriendlyName "reprobados-$Svc" `
            -Subject "CN=$DOMINIO, O=Reprobados, OU=IT, C=MX" `
            -KeyAlgorithm RSA -KeyLength 2048 `
            -KeyExportPolicy Exportable

        $pass = ConvertTo-SecureString "reprobados123" -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath "$CERT_DIR\$($Svc.ToLower()).pfx" -Password $pass | Out-Null

        Log "OK: Certificado generado." Green
        Log "    CN=$DOMINIO | Thumbprint=$($cert.Thumbprint)" White
        $script:RESUMEN += "OK Certificado: $Svc | CN=$DOMINIO"
        return $cert
    } catch {
        Log "ERROR generando certificado: $_" Red
        return $null
    }
}

# ============================================================
#   EXPORTAR CERTIFICADO A FORMATO PEM (sin OpenSSL)
# ============================================================
function ExportPEM {
    param([string]$Svc, [string]$Crt, [string]$Key)
    $pfx  = "$CERT_DIR\$($Svc.ToLower()).pfx"
    $pass = "reprobados123"
    Log "Exportando PEM para $Svc..." Cyan

    # Buscar openssl en el sistema
    function BuscarOpenSSL {
        $rutas = @(
            "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
            "C:\Program Files\OpenSSL\bin\openssl.exe",
            "C:\OpenSSL-Win64\bin\openssl.exe",
            "C:\ProgramData\chocolatey\bin\openssl.exe",
            "C:\tools\openssl\openssl.exe"
        )
        foreach ($r in $rutas) { if (Test-Path $r) { return $r } }
        $cmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        return $null
    }

    $openssl = BuscarOpenSSL

    # Si no hay openssl, instalarlo via chocolatey
    if (-not $openssl) {
        Log "  OpenSSL no encontrado. Instalando via Chocolatey..." Yellow
        $env:Path += ";C:\ProgramData\chocolatey\bin"
        $choco = Get-Command choco -ErrorAction SilentlyContinue
        if (-not $choco) {
            Log "  Instalando Chocolatey primero..." Cyan
            try {
                Set-ExecutionPolicy Bypass -Scope Process -Force
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                $cs = (New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1")
                Invoke-Expression $cs
                $env:Path += ";C:\ProgramData\chocolatey\bin"
            } catch { Log "  Fallo instalar Chocolatey: $_" Red }
        }
        & choco install openssl --yes --no-progress --force 2>&1 | Out-Null
        $env:Path += ";C:\Program Files\OpenSSL-Win64\bin"
        $openssl = BuscarOpenSSL
    }

    if ($openssl) {
        Log "  Usando OpenSSL: $openssl" Cyan
        # Exportar certificado publico
        & "$openssl" pkcs12 -in "$pfx" -clcerts -nokeys -out "$Crt" -passin "pass:$pass" -legacy 2>$null
        if (-not (Test-Path $Crt) -or (Get-Item $Crt).Length -lt 100) {
            & "$openssl" pkcs12 -in "$pfx" -clcerts -nokeys -out "$Crt" -passin "pass:$pass" 2>$null
        }
        # Exportar clave privada
        & "$openssl" pkcs12 -in "$pfx" -nocerts -nodes -out "$Key" -passin "pass:$pass" -legacy 2>$null
        if (-not (Test-Path $Key) -or (Get-Item $Key).Length -lt 100) {
            & "$openssl" pkcs12 -in "$pfx" -nocerts -nodes -out "$Key" -passin "pass:$pass" 2>$null
        }
        if ((Test-Path $Crt) -and (Test-Path $Key) -and
            (Get-Item $Crt).Length -gt 100 -and (Get-Item $Key).Length -gt 100) {
            Log "OK: CRT ($([int](Get-Item $Crt).Length) bytes) y KEY ($([int](Get-Item $Key).Length) bytes) exportados." Green
            return $true
        }
        Log "  Fallo OpenSSL, intentando metodo alternativo..." Yellow
    }

    # Fallback: generar certificado nuevo directamente con openssl (sin importar pfx)
    if ($openssl) {
        Log "  Generando CRT/KEY directamente con openssl req..." Cyan
        & "$openssl" req -x509 -nodes -days 365 -newkey rsa:2048 `
            -keyout "$Key" -out "$Crt" `
            -subj "/CN=$DOMINIO/O=Reprobados/OU=IT/C=MX" `
            -addext "subjectAltName=DNS:$DOMINIO,DNS:www.$DOMINIO,IP:$MI_IP" 2>$null
        if ((Test-Path $Crt) -and (Test-Path $Key) -and
            (Get-Item $Crt).Length -gt 100 -and (Get-Item $Key).Length -gt 100) {
            Log "OK: CRT y KEY generados directamente con openssl." Green
            return $true
        }
    }

    Log "ERROR: No se pudo exportar PEM por ninguna via." Red
    return $false
}

============================================================
#   ORQUESTADOR - PRACTICA 7 (WINDOWS)
#   Soporta origen WEB o FTP (navegacion dinamica)
#   SSL/TLS: IIS :443 | Apache :4443 | Nginx :8443 | IIS-FTP :21
#   Verificacion SHA256 para instaladores descargados via FTP
#
#   Ejecutar como Administrador:
#   powershell -ExecutionPolicy Bypass -File orquestador_windows_p7.ps1
# ============================================================

# ============================================================
#   CONFIGURACION - CAMBIA ESTAS IPs SEGUN TU ENTORNO
# ============================================================
$MI_IP      = "192.168.137.240"    # IP principal Windows (VMnet8 NAT)
# Detectar IP del servidor FTP dinamicamente
# Se usa la IP que NO sea NAT (192.168.137.x) ni loopback
$FTP_SERVER = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch "^127\." -and
                   $_.IPAddress -notmatch "^192\.168\.137\." -and
                   $_.IPAddress -ne "0.0.0.0" } |
    Select-Object -First 1).IPAddress
if (-not $FTP_SERVER) { $FTP_SERVER = "127.0.0.1" }
$FTP_USER   = "usuario"
$FTP_PASS   = "1234"
$FTP_PORT   = 21

# ============================================================
#   VARIABLES GLOBALES
# ============================================================
$DOMINIO  = "reprobados.com"
$CERT_DIR = "C:\SSL\reprobados"
$LOG_FILE = "C:\Logs\orquestador.log"
$RESUMEN  = @()
$SERVICIO = ""
$BASE_FTP = "ftp://$FTP_SERVER"

# Directorios de trabajo
foreach ($d in @($CERT_DIR, "C:\Logs", "C:\Temp", "C:\opt")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
if (-not (Test-Path $LOG_FILE)) { New-Item -ItemType File -Force -Path $LOG_FILE | Out-Null }

# Verificar privilegios de administrador
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $esAdmin) {
    Write-Host "ERROR: Debes ejecutar este script como Administrador." -ForegroundColor Red
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================
#   FUNCIONES UTILITARIAS
# ============================================================

function Log {
    param([string]$M, [string]$C = "White")
    Write-Host $M -ForegroundColor $C
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $M" | Out-File -Append -FilePath $LOG_FILE -Encoding UTF8
}

function SinBOM {
    param([string]$P, [string]$C)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($P, $C, $enc)
}

function BuscarExe {
    param([string]$N)
    $rutas = @("C:\opt\","C:\Apache24\","C:\tools\","C:\ProgramData\chocolatey\lib\",
               "$env:APPDATA\","C:\Program Files\","C:\Program Files (x86)\")
    foreach ($r in $rutas) {
        if (Test-Path $r) {
            $found = Get-ChildItem $r -Recurse -Filter $N -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found }
        }
    }
    return $null
}

# ============================================================
#   DESCARGAR DESDE WEB (3 metodos)
# ============================================================
function Bajar {
    param([string]$Url, [string]$Dest)
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 1: curl
    Log "  [curl] $Url" Cyan
    & curl.exe -L --connect-timeout 30 --max-time 600 --progress-bar -o "$Dest" "$Url" 2>&1
    if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) {
        Log "  OK curl: $([math]::Round((Get-Item $Dest).Length/1MB,1)) MB" Green
        return $true
    }
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 2: Invoke-WebRequest
    Log "  [Invoke-WebRequest] $Url" Cyan
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) {
            Log "  OK IWR: $([math]::Round((Get-Item $Dest).Length/1MB,1)) MB" Green
            return $true
        }
    } catch { Log "  Fallo IWR: $_" Yellow }
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 3: WebClient
    Log "  [WebClient] $Url" Cyan
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $Dest)
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) {
            Log "  OK WebClient: $([math]::Round((Get-Item $Dest).Length/1MB,1)) MB" Green
            return $true
        }
    } catch { Log "  Fallo WebClient: $_" Yellow }
    Remove-Item $Dest -ErrorAction SilentlyContinue
    return $false
}

# ============================================================
#   CLIENTE FTP DINAMICO - NAVEGAR ESTRUCTURA REMOTA
# ============================================================

function FTP_ListarDirectorio {
    param([string]$RutaFTP)
    # Usa curl para listar el directorio FTP
    $resultado = & curl.exe --silent --ftp-ssl --insecure --ftp-pasv `
        -u "${FTP_USER}:${FTP_PASS}" `
        --list-only `
        "$BASE_FTP$RutaFTP/" 2>&1
    # Filtrar lineas vacias y el archivo .keep
    return ($resultado | Where-Object { $_ -and $_ -notmatch "^\.keep$" -and $_ -notmatch "^\s*$" })
}

function FTP_DescargarArchivo {
    param([string]$RutaFTP, [string]$DestLocal)
    Remove-Item $DestLocal -ErrorAction SilentlyContinue
    Log "  Descargando desde FTP: $RutaFTP" Cyan
    & curl.exe --silent --show-error --ftp-ssl --insecure --ftp-pasv `
        -u "${FTP_USER}:${FTP_PASS}" `
        -o "$DestLocal" `
        "$BASE_FTP$RutaFTP" 2>&1
    if ((Test-Path $DestLocal) -and (Get-Item $DestLocal).Length -gt 1000) {
        Log "  OK: $([math]::Round((Get-Item $DestLocal).Length/1MB,2)) MB descargados." Green
        return $true
    }
    Log "  ERROR: Archivo no descargado o vacio." Red
    return $false
}

function FTP_DescargarDesdeRepositorio {
    param([string]$OS)   # "Windows" o "Linux"

    Log "" White
    Log "========================================" Cyan
    Log "  CLIENTE FTP DINAMICO - reprobados.com " Cyan
    Log "========================================" Cyan
    Log "  Servidor: $FTP_SERVER" White
    Log "  OS detectado: $OS" White
    Log "" White

    # Verificar conexion FTP
    Log "Verificando conexion FTP..." Cyan
    $test = & curl.exe --silent --ftp-ssl --insecure --connect-timeout 10 `
        -u "${FTP_USER}:${FTP_PASS}" "$BASE_FTP/" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log "ERROR: No se pudo conectar al FTP $FTP_SERVER" Red
        Log "  Asegurate que vsftpd/FileZilla este corriendo en $FTP_SERVER" Yellow
        return $null
    }
    Log "OK: FTP conectado." Green

    # NIVEL 1: listar /http/[OS]/
    $rutaOS = "/http/$OS"
    Log "" White
    Log "Carpetas disponibles en ${rutaOS}:" Cyan
    $servicios = FTP_ListarDirectorio $rutaOS
    if (-not $servicios) {
        Log "ERROR: No se encontraron carpetas en $rutaOS" Red
        return $null
    }

    $i = 1
    $mapaServicios = @{}
    foreach ($s in $servicios) {
        Write-Host "  $i) $s" -ForegroundColor White
        $mapaServicios[$i.ToString()] = $s
        $i++
    }
    Write-Host ""
    $eleccionSvc = Read-Host "  Selecciona el servicio (numero)"
    if (-not $mapaServicios.ContainsKey($eleccionSvc)) {
        Log "Seleccion invalida." Red
        return $null
    }
    $svcElegido = $mapaServicios[$eleccionSvc]
    $rutaSvc = "$rutaOS/$svcElegido"

    # NIVEL 2: listar archivos en /http/[OS]/[Servicio]/
    Log "" White
    Log "Archivos disponibles en ${rutaSvc}:" Cyan
    $archivos = FTP_ListarDirectorio $rutaSvc
    # Solo mostrar binarios (no .sha256)
    $binarios = $archivos | Where-Object { $_ -notmatch "\.sha256$" -and $_ -notmatch "\.md5$" }

    if (-not $binarios) {
        Log "ERROR: No se encontraron instaladores en $rutaSvc" Red
        return $null
    }

    $j = 1
    $mapaArchivos = @{}
    foreach ($a in $binarios) {
        Write-Host "  $j) $a" -ForegroundColor White
        $mapaArchivos[$j.ToString()] = $a
        $j++
    }
    Write-Host ""
    $eleccionArch = Read-Host "  Selecciona el archivo a descargar (numero)"
    if (-not $mapaArchivos.ContainsKey($eleccionArch)) {
        Log "Seleccion invalida." Red
        return $null
    }
    $archivoElegido = $mapaArchivos[$eleccionArch]
    $rutaArchivo = "$rutaSvc/$archivoElegido"
    $destLocal   = "C:\Temp\$archivoElegido"
    $destHash    = "C:\Temp\$archivoElegido.sha256"

    # Descargar el binario
    if (-not (FTP_DescargarArchivo $rutaArchivo $destLocal)) {
        return $null
    }

    # ============================
    # VERIFICACION SHA256
    # ============================
    Log "" White
    Log "Verificando integridad SHA256..." Cyan
    $rutaHash = "$rutaArchivo.sha256"
    $hashOK = $false

    if (FTP_DescargarArchivo $rutaHash $destHash) {
        try {
            $hashEsperado = (Get-Content $destHash -Raw).Trim().Split(" ")[0].ToLower()
            $hashReal     = (Get-FileHash -Algorithm SHA256 -Path $destLocal).Hash.ToLower()
            if ($hashReal -eq $hashEsperado) {
                Log "OK: SHA256 verificado correctamente." Green
                Log "  Esperado : $hashEsperado" White
                Log "  Calculado: $hashReal" White
                $script:RESUMEN += "OK Hash SHA256: $archivoElegido"
                $hashOK = $true
            } else {
                Log "ERROR: Hash SHA256 NO coincide. Archivo posiblemente corrompido." Red
                Log "  Esperado : $hashEsperado" Red
                Log "  Calculado: $hashReal" Red
                $script:RESUMEN += "FALLO Hash SHA256: $archivoElegido"
                $continuar = Read-Host "  Deseas continuar de todas formas? [S/N]"
                if ($continuar -notmatch "^[sSyY]") { return $null }
            }
        } catch {
            Log "AVISO: No se pudo verificar hash: $_" Yellow
            $hashOK = $true  # Continuar si no hay hash disponible
        }
    } else {
        Log "AVISO: No se encontro archivo .sha256 en FTP. Saltando verificacion." Yellow
        $script:RESUMEN += "AVISO: Sin hash para $archivoElegido"
        $hashOK = $true
    }

    return @{
        Archivo  = $destLocal
        Servicio = $svcElegido
        HashOK   = $hashOK
    }
}

# ============================================================
#   INSTALACION DESDE FTP (manual/silenciosa)
# ============================================================
function InstalarDesdeFTP {
    param([string]$Archivo, [string]$Svc)
    Log "" White
    Log "Instalando $Svc desde: $Archivo" Cyan

    switch -Wildcard ($Archivo) {
        "*.zip" {
            Log "  Extrayendo ZIP en C:\opt\" Cyan
            try {
                Expand-Archive -Path $Archivo -DestinationPath "C:\opt\" -Force
                Log "  OK: Extraido en C:\opt\" Green
                $script:RESUMEN += "OK Instalacion FTP: $Svc (zip)"
            } catch { Log "  ERROR extrayendo: $_" Red }
        }
        "*.msi" {
            Log "  Instalando MSI silenciosamente..." Cyan
            $args = "/i `"$Archivo`" /quiet /norestart /log C:\Logs\install_$Svc.log"
            Start-Process msiexec.exe -ArgumentList $args -Wait -NoNewWindow
            Log "  OK: MSI instalado." Green
            $script:RESUMEN += "OK Instalacion FTP: $Svc (msi)"
        }
        "*.exe" {
            Log "  Ejecutando instalador silencioso..." Cyan
            Start-Process $Archivo -ArgumentList "/S /silent /quiet" -Wait -NoNewWindow
            Log "  OK: EXE instalado." Green
            $script:RESUMEN += "OK Instalacion FTP: $Svc (exe)"
        }
        default {
            Log "  AVISO: Tipo de archivo no reconocido para instalacion automatica." Yellow
            Log "  Archivo disponible en: $Archivo" White
        }
    }
}

# ============================================================
#   INSTALAR DESDE WEB
# ============================================================
function ObtenerApache {
    $exe = BuscarExe "httpd.exe"
    if ($exe) { Log "OK: Apache ya instalado en $($exe.FullName)" Green; return $exe.FullName }

    Log "Descargando Apache desde internet..." Cyan
    $dest = "C:\Temp\apache_win.zip"

    # Instalar via Chocolatey (mas confiable que descargar ZIP)
    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $choco) {
        Log "  Instalando Chocolatey..." Cyan
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $chocoScript = (New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1")
            Invoke-Expression $chocoScript
            $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
            $choco = Get-Command choco -ErrorAction SilentlyContinue
        } catch { Log "  Fallo Chocolatey: $_" Yellow }
    }

    if ($choco) {
        Log "  Instalando Apache via Chocolatey..." Cyan
        & choco install apache-httpd --yes --no-progress --force 2>&1 | ForEach-Object { Write-Host "  $_" }
        # Chocolatey puede instalarlo en AppData - buscarlo y copiarlo a C:\opt\Apache24
        $exe2 = BuscarExe "httpd.exe"
        if ($exe2) {
            $srcDir = Split-Path (Split-Path $exe2.FullName)
            $dstDir = "C:\opt\Apache24"
            if ($srcDir -ne $dstDir) {
                Log "  Copiando Apache de $srcDir a $dstDir ..." Cyan
                if (Test-Path $dstDir) { Remove-Item $dstDir -Recurse -Force -ErrorAction SilentlyContinue }
                Copy-Item $srcDir $dstDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            $httpd = "$dstDir\bin\httpd.exe"
            if (-not (Test-Path $httpd)) { $httpd = $exe2.FullName }
            # Detener el servicio Apache instalado por choco (usa puerto 443, lo necesitamos en 4443)
            & sc.exe stop Apache 2>$null | Out-Null
            & sc.exe delete Apache 2>$null | Out-Null
            Start-Sleep -Seconds 2
            Log "OK: Apache listo en $httpd" Green
            return $httpd
        }
    }

    # Fallback: descargar ZIP desde GitHub mirror
    $urls = @(
        "https://github.com/thebugfix/ApacheWindowsBuild/releases/latest/download/Apache24.zip",
        "https://sourceforge.net/projects/apache-httpd-win64/files/latest/download",
        "https://downloads.apache.org/httpd/binaries/win32/"
    )
    $ok = $false
    foreach ($url in $urls) {
        Log "  Intentando ZIP: $url" Cyan
        Remove-Item $dest -ErrorAction SilentlyContinue
        & curl.exe -L --insecure -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
            --connect-timeout 30 --max-time 600 --retry 2 -o "$dest" "$url" 2>&1 | Out-Null
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 500000) {
            Log "  OK: $([math]::Round((Get-Item $dest).Length/1MB,1)) MB" Green
            $ok = $true; break
        }
        Remove-Item $dest -ErrorAction SilentlyContinue
    }

    if ($ok) {
        try { Expand-Archive -Path $dest -DestinationPath "C:\opt\" -Force -ErrorAction Stop }
        catch { Log "ERROR extrayendo Apache: $_" Red; return $null }
    } else {
        Log "ERROR: No se pudo obtener Apache por ninguna via." Red
        return $null
    }

    $exe = BuscarExe "httpd.exe"
    if ($exe) { Log "OK: Apache en $($exe.FullName)" Green; return $exe.FullName }
    Log "ERROR: httpd.exe no encontrado." Red; return $null
}

function ObtenerNginx {
    $exe = BuscarExe "nginx.exe"
    if ($exe) { Log "OK: Nginx ya instalado en $($exe.FullName)" Green; return $exe.FullName }

    Log "Descargando Nginx desde internet..." Cyan
    $dest = "C:\Temp\nginx_win.zip"

    # Nginx.org permite descarga directa sin problemas de redirect
    $urls = @(
        "https://nginx.org/download/nginx-1.26.2.zip",
        "https://nginx.org/download/nginx-1.26.1.zip",
        "https://nginx.org/download/nginx-1.24.0.zip",
        "https://nginx.org/download/nginx-1.22.1.zip"
    )
    $ok = $false
    foreach ($url in $urls) {
        Log "  Intentando: $url" Cyan
        Remove-Item $dest -ErrorAction SilentlyContinue
        & curl.exe -L --insecure -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
            --connect-timeout 30 --max-time 300 --retry 3 -o "$dest" "$url" 2>&1 | Out-Null
        if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 500000) {
            Log "  OK curl: $([math]::Round((Get-Item $dest).Length/1MB,1)) MB" Green
            $ok = $true; break
        }
        Remove-Item $dest -ErrorAction SilentlyContinue
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            $wc.DownloadFile($url, $dest)
            if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 500000) {
                Log "  OK WebClient: $([math]::Round((Get-Item $dest).Length/1MB,1)) MB" Green
                $ok = $true; break
            }
        } catch { }
        Remove-Item $dest -ErrorAction SilentlyContinue
    }

    # Fallback: Chocolatey
    if (-not $ok) {
        $choco = Get-Command choco -ErrorAction SilentlyContinue
        if ($choco) {
            Log "  Instalando Nginx via Chocolatey..." Cyan
            & choco install nginx --yes --no-progress --force 2>&1 | ForEach-Object { Write-Host "  $_" }
            $exe2 = BuscarExe "nginx.exe"
            if ($exe2) { Log "OK: Nginx via Chocolatey en $($exe2.FullName)" Green; return $exe2.FullName }
        }
    }

    if (-not $ok) { Log "ERROR: No se pudo obtener Nginx." Red; return $null }
    try { Expand-Archive -Path $dest -DestinationPath "C:\opt\" -Force -ErrorAction Stop }
    catch { Log "ERROR extrayendo Nginx: $_" Red; return $null }

    $exe = BuscarExe "nginx.exe"
    if ($exe) { Log "OK: Nginx en $($exe.FullName)" Green; return $exe.FullName }
    Log "ERROR: nginx.exe no encontrado tras extraccion." Red; return $null
}

function InstFeat {
    param([string]$F)
    try {
        Install-WindowsFeature -Name $F -IncludeManagementTools -ErrorAction Stop | Out-Null
        Log "OK: $F habilitado." Green; return $true
    } catch {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName $F -NoRestart -ErrorAction Stop | Out-Null
            Log "OK: $F habilitado." Green; return $true
        } catch { Log "AVISO: $F no habilitado: $_" Yellow; return $false }
    }
}

function InstWeb {
    Log "Instalando $SERVICIO desde WEB..." Cyan
    switch ($SERVICIO) {
        "IIS" {
            InstFeat "Web-Server"
            InstFeat "Web-Common-Http"
            InstFeat "Web-Static-Content"
            InstFeat "Web-Default-Doc"
            InstFeat "Web-Http-Errors"
            & iisreset /start 2>$null
            Set-Service W3SVC -StartupType Automatic -ErrorAction SilentlyContinue
        }
        "Apache" { ObtenerApache | Out-Null }
        "Nginx"  { ObtenerNginx  | Out-Null }
        "FTP" {
            InstFeat "Web-Ftp-Server"
            InstFeat "Web-Ftp-Service"
            InstFeat "Web-Ftp-Ext"
            & iisreset /start 2>$null
        }
    }
    $script:RESUMEN += "OK Instalacion WEB: $SERVICIO"
}

# ============================================================
#   PAGINA WEB - HTTP (muestra "No seguro")
# ============================================================
function PaginaHTTP {
    param([string]$P, [string]$S, [string]$Port)
    $h = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>reprobados.com - $S (HTTP)</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Orbitron:wght@400;700&display=swap');
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #0d0d0d;
      color: #e0e0e0;
      font-family: 'Share Tech Mono', monospace;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
    }
    .warning-bar {
      background: #ff4444;
      color: white;
      width: 100%;
      text-align: center;
      padding: 12px;
      font-size: 14px;
      letter-spacing: 2px;
      font-weight: bold;
      position: fixed;
      top: 0;
    }
    .lock-icon { font-size: 18px; margin-right: 8px; }
    .container {
      background: #1a1a1a;
      border: 1px solid #333;
      border-top: 4px solid #ff4444;
      padding: 40px 50px;
      border-radius: 4px;
      text-align: center;
      max-width: 600px;
      margin-top: 60px;
    }
    h1 {
      font-family: 'Orbitron', monospace;
      color: #ff4444;
      font-size: 2em;
      margin-bottom: 8px;
      letter-spacing: 3px;
    }
    .subtitle { color: #888; font-size: 12px; letter-spacing: 4px; margin-bottom: 30px; }
    .badge {
      display: inline-block;
      background: #ff444422;
      border: 1px solid #ff4444;
      color: #ff4444;
      padding: 8px 20px;
      border-radius: 2px;
      font-size: 13px;
      letter-spacing: 2px;
      margin-bottom: 25px;
    }
    .info-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 15px;
      margin-top: 20px;
    }
    .info-item {
      background: #111;
      border: 1px solid #2a2a2a;
      padding: 15px;
      border-radius: 2px;
      text-align: left;
    }
    .info-label { color: #555; font-size: 10px; letter-spacing: 3px; }
    .info-value { color: #00ff88; font-size: 14px; margin-top: 4px; }
    .http-warning { color: #ff6666; }
    .footer { margin-top: 30px; color: #444; font-size: 11px; }
  </style>
</head>
<body>
  <div class="warning-bar">
    <span class="lock-icon">&#x26A0;</span>
    NO ES SEGURO - La conexion no esta cifrada (HTTP)
  </div>
  <div class="container">
    <h1>reprobados.com</h1>
    <div class="subtitle">PRACTICA 7 - INFRAESTRUCTURA DE DESPLIEGUE</div>
    <div class="badge">&#x1F513; CONEXION NO CIFRADA</div>
    <div class="info-grid">
      <div class="info-item">
        <div class="info-label">SERVIDOR</div>
        <div class="info-value">$S</div>
      </div>
      <div class="info-item">
        <div class="info-label">PROTOCOLO</div>
        <div class="info-value http-warning">HTTP (sin cifrar)</div>
      </div>
      <div class="info-item">
        <div class="info-label">PUERTO</div>
        <div class="info-value">$Port</div>
      </div>
      <div class="info-item">
        <div class="info-label">IP SERVIDOR</div>
        <div class="info-value">$MI_IP</div>
      </div>
    </div>
    <div class="footer">Este sitio no tiene certificado SSL activo</div>
  </div>
</body>
</html>
"@
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($P, $h, $enc)
}

# ============================================================
#   PAGINA WEB - HTTPS (muestra dominio y SSL activo)
# ============================================================
function PaginaHTTPS {
    param([string]$P, [string]$S, [string]$Port)
    $h = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>reprobados.com - $S (HTTPS)</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Orbitron:wght@400;700&display=swap');
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #050d1a;
      color: #c8d8f0;
      font-family: 'Share Tech Mono', monospace;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      background-image: radial-gradient(ellipse at 20% 50%, #0a1f3d 0%, transparent 60%),
                        radial-gradient(ellipse at 80% 20%, #001a2e 0%, transparent 50%);
    }
    .secure-bar {
      background: linear-gradient(90deg, #004d1a, #006622);
      color: #00ff88;
      width: 100%;
      text-align: center;
      padding: 12px;
      font-size: 14px;
      letter-spacing: 2px;
      position: fixed;
      top: 0;
      border-bottom: 1px solid #00ff8844;
    }
    .container {
      background: rgba(10,25,50,0.9);
      border: 1px solid #1a3a6a;
      border-top: 4px solid #00d4ff;
      padding: 40px 50px;
      border-radius: 4px;
      text-align: center;
      max-width: 650px;
      margin-top: 60px;
      box-shadow: 0 0 40px rgba(0,100,200,0.15);
    }
    h1 {
      font-family: 'Orbitron', monospace;
      color: #00d4ff;
      font-size: 2.2em;
      margin-bottom: 6px;
      letter-spacing: 4px;
      text-shadow: 0 0 20px rgba(0,212,255,0.5);
    }
    .subtitle { color: #4a7aaa; font-size: 11px; letter-spacing: 5px; margin-bottom: 30px; }
    .badge-ssl {
      display: inline-block;
      background: #00ff8811;
      border: 1px solid #00ff88;
      color: #00ff88;
      padding: 8px 20px;
      border-radius: 2px;
      font-size: 13px;
      letter-spacing: 2px;
      margin-bottom: 25px;
    }
    .cert-box {
      background: #071428;
      border: 1px solid #1a3a6a;
      border-left: 4px solid #00d4ff;
      padding: 20px;
      margin: 20px 0;
      text-align: left;
      border-radius: 2px;
    }
    .cert-title { color: #00d4ff; font-size: 11px; letter-spacing: 4px; margin-bottom: 12px; }
    .cert-row { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #0d2040; }
    .cert-row:last-child { border-bottom: none; }
    .cert-key { color: #4a7aaa; font-size: 11px; }
    .cert-val { color: #c8d8f0; font-size: 12px; }
    .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 20px; }
    .info-item { background: #071428; border: 1px solid #1a3a6a; padding: 14px; border-radius: 2px; text-align: left; }
    .info-label { color: #3a5a8a; font-size: 10px; letter-spacing: 3px; }
    .info-value { color: #00ff88; font-size: 13px; margin-top: 4px; }
    .footer { margin-top: 25px; color: #2a4a7a; font-size: 11px; }
  </style>
</head>
<body>
  <div class="secure-bar">
    &#x1F512; CONEXION SEGURA - Certificado TLS activo para reprobados.com
  </div>
  <div class="container">
    <h1>reprobados.com</h1>
    <div class="subtitle">PRACTICA 7 - INFRAESTRUCTURA DE DESPLIEGUE</div>
    <div class="badge-ssl">&#x2705; HTTPS ACTIVO - CANAL CIFRADO</div>

    <div class="cert-box">
      <div class="cert-title">INFORMACION DEL CERTIFICADO SSL/TLS</div>
      <div class="cert-row">
        <span class="cert-key">Emitido para</span>
        <span class="cert-val">reprobados.com</span>
      </div>
      <div class="cert-row">
        <span class="cert-key">Organizacion</span>
        <span class="cert-val">Reprobados - IT</span>
      </div>
      <div class="cert-row">
        <span class="cert-key">Algoritmo</span>
        <span class="cert-val">RSA 2048-bit</span>
      </div>
      <div class="cert-row">
        <span class="cert-key">Tipo</span>
        <span class="cert-val">Self-Signed (Autofirmado)</span>
      </div>
      <div class="cert-row">
        <span class="cert-key">Protocolo</span>
        <span class="cert-val">TLS 1.2 / TLS 1.3</span>
      </div>
      <div class="cert-row">
        <span class="cert-key">HSTS</span>
        <span class="cert-val">max-age=31536000; includeSubDomains</span>
      </div>
    </div>

    <div class="info-grid">
      <div class="info-item">
        <div class="info-label">SERVIDOR</div>
        <div class="info-value">$S</div>
      </div>
      <div class="info-item">
        <div class="info-label">PROTOCOLO</div>
        <div class="info-value">HTTPS (TLS)</div>
      </div>
      <div class="info-item">
        <div class="info-label">PUERTO</div>
        <div class="info-value">$Port</div>
      </div>
      <div class="info-item">
        <div class="info-label">IP SERVIDOR</div>
        <div class="info-value">$MI_IP</div>
      </div>
    </div>
    <div class="footer">Practica 7 - Seguridad SSL/TLS en infraestructura de despliegue</div>
  </div>
</body>
</html>
"@
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($P, $h, $enc)
}

# ============================================================
#   GENERAR CERTIFICADO AUTOFIRMADO
# ============================================================
function GenCert {
    param([string]$Svc)
    Log "Generando certificado autofirmado para $Svc..." Cyan

    # Eliminar certificados anteriores del mismo servicio
    Get-ChildItem "Cert:\LocalMachine\My" |
        Where-Object { $_.FriendlyName -eq "reprobados-$Svc" } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    try {
        $cert = New-SelfSignedCertificate `
            -DnsName $DOMINIO, "www.$DOMINIO", $MI_IP `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddDays(365) `
            -FriendlyName "reprobados-$Svc" `
            -Subject "CN=$DOMINIO, O=Reprobados, OU=IT, C=MX" `
            -KeyAlgorithm RSA -KeyLength 2048 `
            -KeyExportPolicy Exportable

        $pass = ConvertTo-SecureString "reprobados123" -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath "$CERT_DIR\$($Svc.ToLower()).pfx" -Password $pass | Out-Null

        Log "OK: Certificado generado." Green
        Log "    CN=$DOMINIO | Thumbprint=$($cert.Thumbprint)" White
        $script:RESUMEN += "OK Certificado: $Svc | CN=$DOMINIO"
        return $cert
    } catch {
        Log "ERROR generando certificado: $_" Red
        return $null
    }
}

# ============================================================
#   EXPORTAR CERTIFICADO A FORMATO PEM (sin OpenSSL)
# ============================================================
function ExportPEM {
    param([string]$Svc, [string]$Crt, [string]$Key)
    $pfx  = "$CERT_DIR\$($Svc.ToLower()).pfx"
    $pass = "reprobados123"
    Log "Exportando PEM para $Svc..." Cyan

    # Metodo 1: openssl si esta disponible
    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if (-not $openssl) {
        $opensslPaths = @(
            "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
            "C:\Program Files\OpenSSL\bin\openssl.exe",
            "C:\OpenSSL-Win64\bin\openssl.exe",
            "C:\ProgramData\chocolatey\bin\openssl.exe"
        )
        foreach ($p in $opensslPaths) {
            if (Test-Path $p) { $openssl = $p; break }
        }
    } else { $openssl = $openssl.Source }

    if ($openssl) {
        Log "  Usando openssl para exportar PEM..." Cyan
        & $openssl pkcs12 -in "$pfx" -clcerts -nokeys -out "$Crt" -passin pass:reprobados123 2>$null
        & $openssl pkcs12 -in "$pfx" -nocerts -nodes  -out "$Key" -passin pass:reprobados123 2>$null
        if ((Test-Path $Crt) -and (Test-Path $Key) -and
            (Get-Item $Crt).Length -gt 100 -and (Get-Item $Key).Length -gt 100) {
            Log "OK: CRT y KEY exportados con openssl." Green
            return $true
        }
        Log "  Fallo openssl, intentando metodo .NET..." Yellow
    }

    # Metodo 2: Export via PFX con CngKey (compatible con Windows Server 2016/2019/2022)
    try {
        $enc = New-Object System.Text.UTF8Encoding $false
        $secPass = ConvertTo-SecureString "reprobados123" -AsPlainText -Force
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        $flags = $flags -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
        $co = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $pfx, $secPass, $flags
        )

        # Exportar certificado publico
        $b64c = [Convert]::ToBase64String(
            $co.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert),
            [System.Base64FormattingOptions]::InsertLineBreaks)
        [System.IO.File]::WriteAllText($Crt, "-----BEGIN CERTIFICATE-----`r`n$b64c`r`n-----END CERTIFICATE-----", $enc)

        # Exportar clave privada via CngKey (funciona en WS2016/2019/2022)
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($co)
        $exported = $false

        # Intentar ExportPkcs8PrivateKey (.NET 5+ / PowerShell 7)
        try {
            $pkcs8 = $rsa.ExportPkcs8PrivateKey()
            $b64k = [Convert]::ToBase64String($pkcs8, [System.Base64FormattingOptions]::InsertLineBreaks)
            [System.IO.File]::WriteAllText($Key, "-----BEGIN PRIVATE KEY-----`r`n$b64k`r`n-----END PRIVATE KEY-----", $enc)
            $exported = $true
            Log "  Clave exportada con ExportPkcs8PrivateKey." Cyan
        } catch { }

        # Intentar ExportRSAPrivateKey
        if (-not $exported) {
            try {
                $b64k = [Convert]::ToBase64String($rsa.ExportRSAPrivateKey(), [System.Base64FormattingOptions]::InsertLineBreaks)
                [System.IO.File]::WriteAllText($Key, "-----BEGIN RSA PRIVATE KEY-----`r`n$b64k`r`n-----END RSA PRIVATE KEY-----", $enc)
                $exported = $true
                Log "  Clave exportada con ExportRSAPrivateKey." Cyan
            } catch { }
        }

        # Intentar via CngKey.Export
        if (-not $exported) {
            try {
                $cngKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($co)
                $params = $cngKey.ExportParameters($true)
                # Reconstruir con RSACryptoServiceProvider que si tiene Export
                $csp = New-Object System.Security.Cryptography.RSACryptoServiceProvider
                $csp.ImportParameters($params)
                $b64k = [Convert]::ToBase64String($csp.ExportRSAPrivateKey(), [System.Base64FormattingOptions]::InsertLineBreaks)
                [System.IO.File]::WriteAllText($Key, "-----BEGIN RSA PRIVATE KEY-----`r`n$b64k`r`n-----END RSA PRIVATE KEY-----", $enc)
                $exported = $true
                Log "  Clave exportada via RSACryptoServiceProvider." Cyan
            } catch { }
        }

        # Intentar via CspParameters (metodo clasico, siempre disponible)
        if (-not $exported) {
            try {
                $cspParams = New-Object System.Security.Cryptography.CspParameters
                $cspParams.KeyContainerName = $co.Thumbprint
                $cspParams.Flags = [System.Security.Cryptography.CspProviderFlags]::UseExistingKey
                $rsa2 = New-Object System.Security.Cryptography.RSACryptoServiceProvider($cspParams)
                $b64k = [Convert]::ToBase64String($rsa2.ExportCspBlob($true), [System.Base64FormattingOptions]::InsertLineBreaks)
                [System.IO.File]::WriteAllText($Key, "-----BEGIN RSA PRIVATE KEY-----`r`n$b64k`r`n-----END RSA PRIVATE KEY-----", $enc)
                $exported = $true
                Log "  Clave exportada via CspParameters." Cyan
            } catch { }
        }

        if (-not $exported) {
            Log "ERROR: No se pudo exportar la clave privada con ningun metodo .NET." Red
            Log "  Instalando OpenSSL via Chocolatey para exportar..." Yellow
            $choco = Get-Command choco -ErrorAction SilentlyContinue
            if (-not $choco) { $env:Path += ";C:\ProgramData\chocolatey\bin" }
            $choco = Get-Command choco -ErrorAction SilentlyContinue
            if ($choco) {
                & choco install openssl --yes --no-progress 2>&1 | Out-Null
                $env:Path += ";C:\Program Files\OpenSSL-Win64\bin"
                & openssl pkcs12 -in "$pfx" -clcerts -nokeys -out "$Crt" -passin pass:reprobados123 2>$null
                & openssl pkcs12 -in "$pfx" -nocerts -nodes  -out "$Key" -passin pass:reprobados123 2>$null
                if ((Test-Path $Crt) -and (Test-Path $Key)) {
                    Log "OK: CRT y KEY exportados con OpenSSL (choco)." Green
                    return $true
                }
            }
            return $false
        }

        if ((Test-Path $Crt) -and (Test-Path $Key)) {
            Log "OK: CRT y KEY exportados correctamente." Green
            return $true
        }
        Log "ERROR: Archivos PEM no generados." Red
        return $false

    } catch {
        Log "ERROR exportando PEM: $_" Red
        return $false
    }
}

# ============================================================
#   SSL IIS :443
# ============================================================
function SSL_IIS {
    Log "" White
    Log "=== Configurando IIS HTTPS :443 ===" Cyan
    & iisreset /stop 2>$null
    Start-Sleep -Seconds 4

    $cert = GenCert "IIS"
    if (-not $cert) { & iisreset /start 2>$null; return }

    Import-Module WebAdministration -ErrorAction SilentlyContinue
    try {
        $sitio = "Default Web Site"

        # Eliminar bindings HTTPS anteriores
        Get-WebBinding -Name $sitio -Protocol "https" -ErrorAction SilentlyContinue |
            Remove-WebBinding -ErrorAction SilentlyContinue
        Get-ChildItem "IIS:\SslBindings" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        # Crear nuevo binding HTTPS
        New-WebBinding -Name $sitio -Protocol "https" -Port 443 -IPAddress "*" -HostHeader ""

        # Asociar certificado
        Push-Location IIS:\SslBindings
        Get-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" | New-Item "0.0.0.0!443"
        Pop-Location

        # HSTS
        Add-WebConfigurationProperty -PSPath "IIS:\Sites\$sitio" `
            -Filter "system.webServer/httpProtocol/customHeaders" `
            -Name "." -Value @{name="Strict-Transport-Security"; value="max-age=31536000; includeSubDomains"} `
            -ErrorAction SilentlyContinue

        # Redireccion HTTP -> HTTPS
        Set-WebConfigurationProperty -PSPath "IIS:\Sites\$sitio" `
            -Filter "system.webServer/httpRedirect" -Name "enabled" -Value $true -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -PSPath "IIS:\Sites\$sitio" `
            -Filter "system.webServer/httpRedirect" -Name "destination" -Value "https://$MI_IP" -ErrorAction SilentlyContinue

        # Paginas web
        PaginaHTTP  "C:\inetpub\wwwroot\index_http.html" "IIS" "80"
        PaginaHTTPS "C:\inetpub\wwwroot\index.html"      "IIS" "443"

        & iisreset /start 2>$null
        Start-Sleep -Seconds 4
        Log "OK: IIS configurado -> https://$MI_IP" Green
        VerPuerto "IIS" 443

    } catch {
        Log "ERROR configurando IIS SSL: $_" Red
        $script:RESUMEN += "FALLO SSL IIS"
        & iisreset /start 2>$null
    }
}

# ============================================================
#   SSL APACHE :4443
# ============================================================
function SSL_Apache {
    Log "" White
    Log "=== Configurando Apache HTTPS :4443 ===" Cyan

    $binPath = ObtenerApache
    if (-not $binPath) { return }

    # Detener CUALQUIER servicio Apache previo que ocupe puertos
    foreach ($svc in @("Apache","Apache2.4","Apache2","httpd")) {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s) {
            Stop-Service $svc -Force -ErrorAction SilentlyContinue
            & sc.exe delete $svc 2>$null | Out-Null
            Start-Sleep -Seconds 1
        }
    }
    Stop-Process -Name httpd -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $cert = GenCert "Apache"
    if (-not $cert) { return }

    $root  = Split-Path (Split-Path $binPath)
    $conf  = "$root\conf\httpd.conf"
    $crt   = (Join-Path $CERT_DIR "apache.crt")
    $key   = (Join-Path $CERT_DIR "apache.key")

    if (-not (ExportPEM "Apache" $crt $key)) { return }

    $crtF  = $crt  -replace "\\","/"
    $keyF  = $key  -replace "\\","/"
    $rootF = $root -replace "\\","/"
    $ip    = "$MI_IP"  # forzar expansion como string

    # Crear htdocs si no existe
    New-Item -ItemType Directory -Force -Path "$root\htdocs" | Out-Null

    # Reescribir httpd.conf limpio (evitar configuracion vieja de choco)
    $confOriginal = "$root\conf\httpd.conf.orig"
    if (-not (Test-Path $confOriginal)) {
        Copy-Item $conf $confOriginal -Force
    }

    # Actualizar SRVROOT en el conf original
    $c = [System.IO.File]::ReadAllText($conf)
    $rootF_tmp = $root -replace "\\","/"
    $c = $c -replace '(?m)^Define SRVROOT.*$', "Define SRVROOT `"$rootF_tmp`""
    SinBOM $conf $c

    # Comentar Listen 443 en archivos extra (httpd-ssl.conf, httpd-ahssl.conf)
    $enc2 = New-Object System.Text.UTF8Encoding $false
    $extraConfs = @("$root\conf\extra\httpd-ssl.conf", "$root\conf\extra\httpd-ahssl.conf")
    foreach ($ef in $extraConfs) {
        if (Test-Path $ef) {
            $ec = [System.IO.File]::ReadAllText($ef)
            $ec = $ec -replace "(?m)^Listen 443.*$", "# Listen 443 deshabilitado"
            [System.IO.File]::WriteAllText($ef, $ec, $enc2)
            Log "  Deshabilitado Listen 443 en: $(Split-Path $ef -Leaf)" Cyan
        }
    }

    # Siempre restaurar desde backup y reescribir limpio
    if (Test-Path $confOriginal) {
        Copy-Item $confOriginal $conf -Force
        Log "  Restaurado httpd.conf original." Cyan
    }

    $c2 = [System.IO.File]::ReadAllText($conf)

    # Quitar cualquier bloque VirtualHost o Listen 4443 previo
    $c2 = $c2 -replace "(?ms)
?
Listen 4443.*", ""
    $c2 = $c2 -replace "(?ms)<VirtualHost \*:4443>.*?</VirtualHost>", ""
    $c2 = $c2 -replace "(?ms)<VirtualHost \*:80>.*?</VirtualHost>", ""

    # Habilitar modulos necesarios
    $c2 = $c2 -replace "#(LoadModule ssl_module)",           '$1'
    $c2 = $c2 -replace "#(LoadModule socache_shmcb_module)", '$1'
    $c2 = $c2 -replace "#(LoadModule headers_module)",       '$1'
    $c2 = $c2 -replace "#(LoadModule rewrite_module)",       '$1'

    # Quitar Listen 443 de choco
    $c2 = $c2 -replace "(?m)^Listen 443\s*$", "# Listen 443 deshabilitado"
    # Quitar Listen 80 del conf original (IIS ya usa 80, usaremos 8081 para Apache HTTP)
    $c2 = $c2 -replace "(?m)^Listen 80\s*$", "# Listen 80 deshabilitado (IIS lo usa)"

    $vhosts  = "`r`nListen 4443`r`nListen 8081`r`n"
    $vhosts += "<VirtualHost *:4443>`r`n"
    $vhosts += "    ServerName $DOMINIO`r`n"
    $vhosts += "    ServerAlias www.$DOMINIO`r`n"
    $vhosts += "    DocumentRoot `"$rootF/htdocs`"`r`n"
    $vhosts += "    SSLEngine on`r`n"
    $vhosts += "    SSLCertificateFile `"$crtF`"`r`n"
    $vhosts += "    SSLCertificateKeyFile `"$keyF`"`r`n"
    $vhosts += "    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1`r`n"
    $vhosts += "    SSLCipherSuite HIGH:!aNULL:!MD5`r`n"
    $vhosts += "    Header always set Strict-Transport-Security `"max-age=31536000; includeSubDomains`"`r`n"
    $vhosts += "</VirtualHost>`r`n"
    $vhosts += "<VirtualHost *:8081>`r`n"
    $vhosts += "    ServerName $DOMINIO`r`n"
    $vhosts += "    Redirect permanent / https://${ip}:4443/`r`n"
    $vhosts += "</VirtualHost>`r`n"
    SinBOM $conf ($c2 + $vhosts)

    # Crear paginas web
    Remove-Item "$root\htdocs\index.html" -Force -ErrorAction SilentlyContinue
    Remove-Item "$root\htdocs\index_http.html" -Force -ErrorAction SilentlyContinue
    PaginaHTTP  "$root\htdocs\index_http.html" "Apache" "8081"
    PaginaHTTPS "$root\htdocs\index.html"      "Apache" "4443"

    # Verificar configuracion
    $test = & $binPath -t 2>&1
    Log "Config test Apache: $($test -join ' ')" White

    if (($test -join '') -match "Syntax OK") {
        # Instalar como servicio con nombre unico
        & $binPath -k install -n Apache2.4 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        Start-Service Apache2.4 -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4

        if ((Get-Service Apache2.4 -ErrorAction SilentlyContinue).Status -eq "Running") {
            Log "OK: Apache corriendo como servicio Apache2.4." Green
        } else {
            Log "AVISO: Servicio no arranco, ejecutando httpd directamente..." Yellow
            Start-Process $binPath -WorkingDirectory (Split-Path $binPath) -WindowStyle Hidden -ArgumentList "-f `"$conf`""
            Start-Sleep -Seconds 4
            if (Get-Process httpd -ErrorAction SilentlyContinue) {
                Log "OK: Apache corriendo como proceso." Green
            } else {
                # Mostrar error detallado
                $err = & $binPath -e debug 2>&1
                Log "ERROR arranque: $($err -join ' | ')" Red
            }
        }
    } else {
        Log "ERROR: httpd.conf invalido:" Red
        $test | ForEach-Object { Log "  $_" Red }
        return
    }

    Log "OK: Apache HTTPS -> https://${ip}:4443" Green
    VerPuerto "Apache" 4443
}

# ============================================================
#   SSL NGINX :8443
# ============================================================
function SSL_Nginx {
    Log "" White
    Log "=== Configurando Nginx HTTPS :8443 ===" Cyan
    $binPath = ObtenerNginx
    if (-not $binPath) { return }

    $cert = GenCert "Nginx"
    if (-not $cert) { return }

    $root = Split-Path $binPath
    $conf = "$root\conf\nginx.conf"
    $crt  = "$CERT_DIR\nginx.crt"
    $key  = "$CERT_DIR\nginx.key"

    if (-not (ExportPEM "Nginx" $crt $key)) { return }

    $crtF  = $crt  -replace "\\","/"
    $keyF  = $key  -replace "\\","/"

    $c = [System.IO.File]::ReadAllText($conf)
    # Cambiar puerto 80 a 8080 para no chocar con IIS
    $c = $c -replace "(?m)^\s*listen\s+80;", "        listen 8080;"

    if ($c -notmatch "8443") {
        $bloque = @"

    server {
        listen 8443 ssl;
        server_name $DOMINIO www.$DOMINIO $MI_IP;

        ssl_certificate     $crtF;
        ssl_certificate_key $keyF;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

        location / {
            root   html;
            index  index.html index.htm;
        }
    }

    server {
        listen 8080;
        server_name $DOMINIO www.$DOMINIO $MI_IP;
        return 301 https://`$host:8443`$request_uri;
    }
"@
        $c = $c -replace "(http\s*\{)", "`$1$bloque"
    } else {
        $c = $c -replace "ssl_certificate\s+[^;]+;",     "ssl_certificate     $crtF;"
        $c = $c -replace "ssl_certificate_key\s+[^;]+;", "ssl_certificate_key $keyF;"
    }
    SinBOM $conf $c

    # Crear paginas
    Remove-Item "$root\html\index.html" -Force -ErrorAction SilentlyContinue
    Remove-Item "$root\html\index_http.html" -Force -ErrorAction SilentlyContinue
    PaginaHTTP  "$root\html\index_http.html" "Nginx" "8080"
    PaginaHTTPS "$root\html\index.html"      "Nginx" "8443"

    # Detener instancias previas y verificar configuracion
    Stop-Process -Name nginx -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $test = & $binPath -t -p $root 2>&1
    Log "Config test Nginx: $test" White

    if ($test -notmatch "failed") {
        Start-Process $binPath -WorkingDirectory $root -WindowStyle Hidden
        Start-Sleep -Seconds 3
        if (Get-Process -Name nginx -ErrorAction SilentlyContinue) {
            Log "OK: Nginx corriendo." Green
        } else {
            Log "ERROR: Nginx no inicio." Red
        }
    } else {
        Log "ERROR: nginx.conf invalido, revisa la configuracion." Red
    }

    Log "OK: Nginx HTTPS -> https://$MI_IP:8443" Green
    VerPuerto "Nginx" 8443
}

# ============================================================
#   SSL IIS-FTP :21 (FTPS)
# ============================================================
function SSL_FTP {
    Log "" White
    Log "=== Configurando IIS-FTP FTPS :21 ===" Cyan
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"

    # 1. Instalar caracteristicas FTP
    Log "  Instalando IIS-FTP..." Cyan
    InstFeat "Web-Ftp-Server"
    InstFeat "Web-Ftp-Service"
    InstFeat "Web-Ftp-Ext"
    & iisreset /start 2>$null | Out-Null
    Start-Sleep -Seconds 3

    # 2. Crear usuario con password compleja
    Log "  Creando usuario 'usuario'..." Cyan
    $ftpPass = "Reprobados123!"
    $secPass = ConvertTo-SecureString $ftpPass -AsPlainText -Force
    try {
        if (Get-LocalUser "usuario" -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name "usuario" -Password $secPass -PasswordNeverExpires $true
            Log "  OK: Password actualizado." Green
        } else {
            New-LocalUser -Name "usuario" -Password $secPass -FullName "FTP User" -PasswordNeverExpires | Out-Null
            Log "  OK: Usuario creado." Green
        }
        Add-LocalGroupMember -Group "Administrators" -Member "usuario" -ErrorAction SilentlyContinue
    } catch { Log "  ERROR: $($_.Exception.Message)" Red }

    # 3. Crear carpetas
    $ftpRoot = "C:\inetpub\ftproot"
    foreach ($d in @("$ftpRoot\http\Windows\Apache","$ftpRoot\http\Windows\Nginx","$ftpRoot\http\Windows\IIS")) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }

    # 4. Permisos con icacls (mas confiable)
    Log "  Aplicando permisos NTFS..." Cyan
    & icacls $ftpRoot /grant "usuario:(OI)(CI)F" /T /Q 2>$null | Out-Null
    & icacls $ftpRoot /grant "IIS_IUSRS:(OI)(CI)F" /T /Q 2>$null | Out-Null
    & icacls $ftpRoot /grant "IUSR:(OI)(CI)F" /T /Q 2>$null | Out-Null
    Log "  OK: Permisos NTFS aplicados." Green

    # 5. Copiar ZIPs y SHA256
    $archivos = @(
        @{src="C:\Temp\apache_win.zip"; dst="$ftpRoot\http\Windows\Apache\apache_win.zip"},
        @{src="C:\Temp\nginx_win.zip";  dst="$ftpRoot\http\Windows\Nginx\nginx_win.zip"}
    )
    foreach ($a in $archivos) {
        if (Test-Path $a.src) {
            Copy-Item $a.src $a.dst -Force
            $h = (Get-FileHash $a.dst -Algorithm SHA256).Hash.ToLower()
            $n = Split-Path $a.dst -Leaf
            "$h  $n" | Out-File "$($a.dst).sha256" -Encoding ASCII
            Log "  OK: $n copiado con SHA256." Green
        } else {
            Log "  AVISO: $($a.src) no encontrado." Yellow
        }
    }

    # 6. Certificado
    $cert = GenCert "IIS-FTP"
    if (-not $cert) { return }

    try {
        # 7. Recrear sitio FTP limpio
        if (Get-WebSite -Name "FTP-reprobados" -ErrorAction SilentlyContinue) {
            & $appcmd delete site "FTP-reprobados" 2>$null | Out-Null
            Start-Sleep -Seconds 2
        }

        # Crear sitio con appcmd directamente
        & $appcmd add site /name:"FTP-reprobados" /bindings:"ftp/*:21:" /physicalPath:"$ftpRoot" 2>$null | Out-Null
        Start-Sleep -Seconds 2

        # 8. Configurar FTP con appcmd (mas confiable que Set-WebConfigurationProperty)
        # Sin aislamiento
        & $appcmd set config -section:system.applicationHost/sites `
            "/[name='FTP-reprobados'].ftpServer.userIsolation.mode:None" /commit:apphost 2>$null | Out-Null

        # Autenticacion basica SI, anonima NO
        & $appcmd set config -section:system.applicationHost/sites `
            "/[name='FTP-reprobados'].ftpServer.security.authentication.basicAuthentication.enabled:True" `
            /commit:apphost 2>$null | Out-Null
        & $appcmd set config -section:system.applicationHost/sites `
            "/[name='FTP-reprobados'].ftpServer.security.authentication.anonymousAuthentication.enabled:False" `
            /commit:apphost 2>$null | Out-Null

        # SSL: permitir (no obligar) para compatibilidad
        & $appcmd set config -section:system.applicationHost/sites `
            "/[name='FTP-reprobados'].ftpServer.security.ssl.controlChannelPolicy:SslAllow" `
            "/[name='FTP-reprobados'].ftpServer.security.ssl.dataChannelPolicy:SslAllow" `
            "/[name='FTP-reprobados'].ftpServer.security.ssl.serverCertHash:$($cert.Thumbprint)" `
            /commit:apphost 2>$null | Out-Null

        # Autorizacion: todos pueden leer y escribir
        & $appcmd set config "FTP-reprobados" -section:system.ftpServer/security/authorization `
            /+"[accessType='Allow',users='*',permissions='Read,Write']" /commit:apphost 2>$null | Out-Null

        # 9. Firewall
        netsh advfirewall firewall delete rule name="FTP21" 2>$null | Out-Null
        netsh advfirewall firewall add rule name="FTP21" protocol=TCP dir=in localport=21 action=allow | Out-Null
        netsh advfirewall firewall add rule name="FTP-Pasivo" protocol=TCP dir=in localport=49152-65535 action=allow | Out-Null

        # 10. Arrancar
        & $appcmd start site "FTP-reprobados" 2>$null | Out-Null
        & iisreset /restart 2>$null | Out-Null
        Start-Sleep -Seconds 5

        $ftpIP = $MI_IP
        Log "OK: FTP listo en $ftpIP:21" Green
        Log "    Usuario  : usuario" White
        Log "    Password : $ftpPass" White
        Log "    Carpeta  : $ftpRoot\http\Windows\" White
        Log "" White
        Log "  Conectar desde FileZilla:" Cyan
        Log "    Host    : $ftpIP" White
        Log "    Puerto  : 21" White
        Log "    Cifrado : Use explicit FTP over TLS if available" White
        $script:RESUMEN += "OK FTP: $ftpIP:21 | usuario / $ftpPass"
        VerPuerto "IIS-FTP" 21

    } catch {
        Log "ERROR: $_" Red
        $script:RESUMEN += "FALLO FTP: IIS-FTP"
    }
}
# ============================================================
#   VERIFICAR PUERTO
# ============================================================
function VerPuerto {
    param([string]$N, [int]$P)
    Start-Sleep -Seconds 2
    $ok = (Test-NetConnection -ComputerName localhost -Port $P -WarningAction SilentlyContinue).TcpTestSucceeded
    if ($ok) {
        Log "OK: $N escuchando en puerto :$P" Green
        $script:RESUMEN += "SSL ACTIVO: $N -> :$P"
    } else {
        Log "AVISO: $N no detectado en puerto :$P (puede tardar unos segundos)" Yellow
        $script:RESUMEN += "SSL PENDIENTE: $N -> :$P"
    }
}

# ============================================================
#   PREGUNTAR SSL
# ============================================================
function PreguntarSSL {
    Write-Host ""
    $a = Read-Host "  Deseas activar SSL en $SERVICIO? [S/N]"
    if ($a -match "^[sSyY]") {
        switch ($SERVICIO) {
            "IIS"    { SSL_IIS    }
            "Apache" { SSL_Apache }
            "Nginx"  { SSL_Nginx  }
            "FTP"    { SSL_FTP    }
        }
    } else {
        Log "SSL omitido para: $SERVICIO" Yellow
        $script:RESUMEN += "SSL omitido: $SERVICIO"
    }
}

# ============================================================
#   RESUMEN FINAL
# ============================================================
function Resumen {
    Write-Host ""
    Write-Host "+====================================================+" -ForegroundColor Cyan
    Write-Host "|         RESUMEN - PRACTICA 7 - reprobados.com     |" -ForegroundColor Cyan
    Write-Host "+====================================================+" -ForegroundColor Cyan
    foreach ($x in $script:RESUMEN) {
        $c = if     ($x -match "^OK")      { "Green"  }
             elseif ($x -match "^FALLO")   { "Red"    }
             elseif ($x -match "^SSL ACTIVO") { "Green" }
             else                          { "Yellow" }
        Write-Host "  $x" -ForegroundColor $c
    }
    Write-Host ""
    Write-Host "  URLs de acceso:" -ForegroundColor Cyan
    Write-Host "    IIS    (HTTP)  -> http://$MI_IP"        -ForegroundColor Yellow
    Write-Host "    IIS    (HTTPS) -> https://$MI_IP"       -ForegroundColor Green
    Write-Host "    Apache (HTTP)  -> http://$MI_IP:8081"   -ForegroundColor Yellow
    Write-Host "    Apache (HTTPS) -> https://$MI_IP:4443"  -ForegroundColor Green
    Write-Host "    Nginx  (HTTP)  -> http://$MI_IP:8080"   -ForegroundColor Yellow
    Write-Host "    Nginx  (HTTPS) -> https://$MI_IP:8443"  -ForegroundColor Green
    Write-Host "    FTP    (FTPS)  -> $MI_IP:21"            -ForegroundColor Green
    Write-Host ""
    Write-Host "  Certificados en  : $CERT_DIR" -ForegroundColor White
    Write-Host "  Log en           : $LOG_FILE"  -ForegroundColor White
    Write-Host ""
    Write-Host "  NOTA: Los navegadores mostraran advertencia de certificado" -ForegroundColor Yellow
    Write-Host "        autofirmado. Al ver detalles veras CN=reprobados.com" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================
#   CONFIGURAR FILEZILLA SERVER + ESTRUCTURA FTP
# ============================================================
function ConfigurarFileZilla {
    Log "" White
    Log "=== Configurando FileZilla Server ===" Cyan

    # Asegurar que chocolatey este en el PATH
    $env:Path += ";C:\ProgramData\chocolatey\bin"

    # Rutas posibles de FileZilla Server
    $fzPaths = @(
        "C:\Program Files\FileZilla Server\FileZilla Server.exe",
        "C:\Program Files (x86)\FileZilla Server\FileZilla Server.exe",
        "C:\ProgramData\chocolatey\lib\filezilla-server\tools\FileZilla Server.exe"
    )
    $fzExe = $null
    foreach ($p in $fzPaths) {
        if (Test-Path $p) { $fzExe = $p; break }
    }

    # Instalar si no existe
    if (-not $fzExe) {
        Log "  Instalando FileZilla Server via Chocolatey..." Cyan
        & choco install filezilla-server --yes --no-progress 2>&1 | Out-Null
        foreach ($p in $fzPaths) {
            if (Test-Path $p) { $fzExe = $p; break }
        }
    }

    if (-not $fzExe) {
        Log "ERROR: FileZilla Server no encontrado." Red
        return $false
    }
    Log "OK: FileZilla Server en $fzExe" Green

    # Arrancar el servicio
    $svc = Get-Service "FileZilla Server" -ErrorAction SilentlyContinue
    if (-not $svc) {
        & sc.exe create "FileZilla Server" binPath= "`"$fzExe`" /service" start= auto 2>$null | Out-Null
    }
    Start-Service "FileZilla Server" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # Crear estructura de carpetas FTP
    $base = "C:\FTP\http\Windows"
    foreach ($d in @("$base\Apache","$base\Nginx")) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Log "OK: Estructura C:\FTP\http\Windows\ creada." Green

    # Copiar ZIPs si existen en Temp
    $archivos = @(
        @{src="C:\Temp\apache_win.zip"; dst="$base\Apache\apache_win.zip"},
        @{src="C:\Temp\nginx_win.zip";  dst="$base\Nginx\nginx_win.zip"}
    )
    foreach ($a in $archivos) {
        if (Test-Path $a.src) {
            Copy-Item $a.src $a.dst -Force
            # Generar SHA256
            $h = (Get-FileHash $a.dst -Algorithm SHA256).Hash.ToLower()
            $nombre = Split-Path $a.dst -Leaf
            "$h  $nombre" | Out-File "$($a.dst).sha256" -Encoding ASCII
            Log "OK: $nombre copiado con SHA256." Green
        } else {
            Log "AVISO: No encontrado $($a.src) - agrega el ZIP manualmente en $($a.dst)" Yellow
        }
    }

    # Configurar FileZilla Server via XML
    $xmlPath = "C:\ProgramData\FileZilla Server\FileZilla Server.xml"
    $xmlPaths = @(
        "C:\ProgramData\FileZilla Server\FileZilla Server.xml",
        "C:\Program Files\FileZilla Server\FileZilla Server.xml",
        "$env:APPDATA\FileZilla Server\FileZilla Server.xml"
    )
    $xmlFile = $null
    foreach ($xp in $xmlPaths) {
        if (Test-Path $xp) { $xmlFile = $xp; break }
    }

    if ($xmlFile) {
        Log "  Configurando usuarios en: $xmlFile" Cyan
        try {
            [xml]$xml = Get-Content $xmlFile
            $users = $xml.SelectSingleNode("//Users")
            if (-not $users) {
                $users = $xml.CreateElement("Users")
                $xml.DocumentElement.AppendChild($users) | Out-Null
            }

            # Eliminar usuario previo si existe
            $existing = $xml.SelectSingleNode("//Users/User[@Name='usuario']")
            if ($existing) { $users.RemoveChild($existing) | Out-Null }

            # Crear usuario nuevo
            $user = $xml.CreateElement("User")
            $user.SetAttribute("Name","usuario")

            # Password (MD5 de "1234" = 81dc9bdb52d04dc20036dbd8313ed055)
            $optPass = $xml.CreateElement("Option")
            $optPass.SetAttribute("Name","Pass")
            $optPass.InnerText = "81dc9bdb52d04dc20036dbd8313ed055"
            $user.AppendChild($optPass) | Out-Null

            $optSalt = $xml.CreateElement("Option")
            $optSalt.SetAttribute("Name","Salt")
            $optSalt.InnerText = ""
            $user.AppendChild($optSalt) | Out-Null

            $optGroup = $xml.CreateElement("Option")
            $optGroup.SetAttribute("Name","Group")
            $optGroup.InnerText = ""
            $user.AppendChild($optGroup) | Out-Null

            # Carpeta compartida
            $folders = $xml.CreateElement("Permissions")
            $perm = $xml.CreateElement("Permission")
            $perm.SetAttribute("Dir","C:\FTP")

            foreach ($attr in @("FileRead","FileWrite","FileDelete","FileAppend","DirCreate","DirDelete","DirList","DirSubdirs","IsHome","AutoCreate")) {
                $opt = $xml.CreateElement("Option")
                $opt.SetAttribute("Name",$attr)
                $opt.InnerText = if ($attr -in @("FileRead","DirList","DirSubdirs","IsHome","AutoCreate")) {"1"} else {"0"}
                $perm.AppendChild($opt) | Out-Null
            }
            $folders.AppendChild($perm) | Out-Null
            $user.AppendChild($folders) | Out-Null
            $users.AppendChild($user) | Out-Null

            $xml.Save($xmlFile)
            Log "OK: Usuario 'usuario' con pass '1234' configurado en FileZilla." Green

            # Reiniciar servicio para aplicar cambios
            Restart-Service "FileZilla Server" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Log "OK: FileZilla Server reiniciado." Green

        } catch {
            Log "ERROR configurando XML: $_" Red
            Log "  Configura manualmente: usuario='usuario' pass='1234' carpeta='C:\FTP'" Yellow
        }
    } else {
        Log "AVISO: XML de FileZilla no encontrado." Yellow
        Log "  Configura manualmente en FileZilla Server:" Yellow
        Log "    Usuario: usuario  |  Contrasena: 1234  |  Carpeta: C:\FTP" Yellow
    }

    # Verificar puerto 21
    Start-Sleep -Seconds 2
    $ok = (Test-NetConnection -ComputerName localhost -Port 21 -WarningAction SilentlyContinue).TcpTestSucceeded
    if ($ok) {
        Log "OK: FTP escuchando en :21" Green
        $script:RESUMEN += "OK FTP: FileZilla corriendo en :21"
    } else {
        Log "AVISO: Puerto 21 no responde aun." Yellow
    }

    Log "" White
    Log "  Conexion FTP:" Cyan
    Log "    Host    : $FTP_SERVER  (desde tu maquina fisica)" White
    Log "    Usuario : usuario" White
    Log "    Pass    : 1234" White
    Log "    Puerto  : 21" White
    Log "    Carpeta : C:\FTP\http\Windows\" White
    return $true
}

# ============================================================
#   MENU PRINCIPAL
# ============================================================
while ($true) {
    Clear-Host
    Write-Host ""
    Write-Host "+================================================+" -ForegroundColor Cyan
    Write-Host "|   ORQUESTADOR P7 - reprobados.com (Windows)   |" -ForegroundColor Cyan
    Write-Host "+================================================+" -ForegroundColor Cyan
    Write-Host "|  Windows IP : $MI_IP                          |" -ForegroundColor White
    Write-Host "|  FTP Linux  : $FTP_SERVER                       |" -ForegroundColor White
    Write-Host "+------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|  1) IIS           HTTPS :443                   |" -ForegroundColor White
    Write-Host "|  2) Apache        HTTPS :4443                  |" -ForegroundColor White
    Write-Host "|  3) Nginx         HTTPS :8443                  |" -ForegroundColor White
    Write-Host "|  4) FTP (IIS-FTP) FTPS  :21                   |" -ForegroundColor White
    Write-Host "|  5) Ver resumen                                |" -ForegroundColor White
    Write-Host "|  6) Configurar FileZilla Server + FTP          |" -ForegroundColor White
    Write-Host "|  7) Salir                                      |" -ForegroundColor White
    Write-Host "+================================================+" -ForegroundColor Cyan
    Write-Host ""

    $serv = Read-Host "  Selecciona servicio [1-6]"
    switch ($serv) {
        "1" { $script:SERVICIO = "IIS"    }
        "2" { $script:SERVICIO = "Apache" }
        "3" { $script:SERVICIO = "Nginx"  }
        "4" { $script:SERVICIO = "FTP"    }
        "5" { Resumen; Read-Host "  Enter para continuar"; continue }
        "6" { ConfigurarFileZilla; Read-Host "  Enter para continuar"; continue }
        "7" { Resumen; exit 0 }
        default { Log "Opcion invalida." Red; Start-Sleep 1; continue }
    }

    Write-Host ""
    Write-Host "  +-- ORIGEN DE INSTALACION --+" -ForegroundColor Cyan
    Write-Host "  | 1) WEB  - Descarga automatica desde internet          |" -ForegroundColor White
    Write-Host "  | 2) FTP  - Repositorio privado ($FTP_SERVER) |" -ForegroundColor White
    Write-Host "  +-------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    $origen = Read-Host "  Selecciona origen [1/2]"

    switch ($origen) {
        "1" {
            InstWeb
            PreguntarSSL
        }
        "2" {
            $resultado = FTP_DescargarDesdeRepositorio "Windows"
            if ($resultado) {
                InstalarDesdeFTP $resultado.Archivo $resultado.Servicio
                PreguntarSSL
            } else {
                Log "ERROR: No se pudo completar la descarga desde FTP." Red
                $script:RESUMEN += "FALLO FTP: $($script:SERVICIO)"
            }
        }
        default { Log "Origen invalido." Red }
    }

    Write-Host ""
    Read-Host "  Presiona Enter para continuar"
}