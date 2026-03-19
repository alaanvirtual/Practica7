# ============================================================
#   PASO 1: PREPARAR FTP WINDOWS
#   Descarga Apache y Nginx y los sube al FTP de Linux
#   Ejecutar como Administrador en Windows:
#   powershell -ExecutionPolicy Bypass -File preparar_ftp_windows.ps1
# ============================================================

$FTP_USER   = "usuario"
$FTP_PASS   = "1234"
$FTP_SERVER = "192.168.100.1"
$BASE_FTP   = "ftp://$FTP_SERVER"
$TMPDIR     = "C:\Temp\prep_win"

New-Item -ItemType Directory -Force -Path $TMPDIR | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $esAdmin) { Write-Host "ERROR: Ejecuta como Administrador" -ForegroundColor Red; exit 1 }

function Log { param([string]$M, [string]$C="White"); Write-Host $M -ForegroundColor $C }

# ============================
# CREAR CARPETA EN FTP
# ============================
function CrearCarpeta { param([string]$Ruta)
    $tmp = "$TMPDIR\_k.tmp"; "" | Out-File $tmp -Encoding ASCII
    & curl.exe --silent --ftp-ssl --insecure --ftp-pasv -u "${FTP_USER}:${FTP_PASS}" --ftp-create-dirs -T "$tmp" "$BASE_FTP$Ruta/.keep" 2>&1 | Out-Null
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Log "   Carpeta: $Ruta" Cyan
}

# ============================
# SUBIR AL FTP
# ============================
function SubirFTP { param([string]$Local, [string]$Remota)
    & curl.exe --silent --show-error --ftp-ssl --insecure --ftp-pasv -u "${FTP_USER}:${FTP_PASS}" -T "$Local" "$BASE_FTP$Remota"
    if ($LASTEXITCODE -eq 0) { Log "   OK: subido -> $Remota" Green }
    else { Log "   ERROR subiendo $Local (exit $LASTEXITCODE)" Red }
}

# ============================
# DESCARGAR CON MULTIPLES METODOS
# ============================
function Descargar { param([string]$Url, [string]$Dest)
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 1: curl
    Log "   curl: $Url" Cyan
    & curl.exe -L --connect-timeout 20 --max-time 600 --progress-bar -o "$Dest" "$Url"
    if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) { Log "   OK: descargado con curl ($([math]::Round((Get-Item $Dest).Length/1MB,1)) MB)" Green; return $true }
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 2: Invoke-WebRequest
    Log "   Invoke-WebRequest: $Url" Cyan
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) { Log "   OK: descargado ($([math]::Round((Get-Item $Dest).Length/1MB,1)) MB)" Green; return $true }
    } catch { Log "   Fallo: $_" Yellow }
    Remove-Item $Dest -ErrorAction SilentlyContinue

    # Metodo 3: WebClient
    Log "   WebClient: $Url" Cyan
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $Dest)
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 500000) { Log "   OK: descargado ($([math]::Round((Get-Item $Dest).Length/1MB,1)) MB)" Green; return $true }
    } catch { Log "   Fallo: $_" Yellow }
    Remove-Item $Dest -ErrorAction SilentlyContinue

    return $false
}

function SHA256 { param([string]$Archivo)
    $hash   = (Get-FileHash -Algorithm SHA256 -Path $Archivo).Hash.ToLower()
    $nombre = Split-Path $Archivo -Leaf
    "$hash  $nombre" | Out-File -FilePath "$Archivo.sha256" -Encoding ASCII
    Log "   SHA256: $(Split-Path $Archivo.sha256 -Leaf)" Cyan
}

# ============================
# VERIFICAR FTP
# ============================
Log "" White
Log "Verificando conexion FTP a $FTP_SERVER ..." Cyan
& curl.exe --silent --ftp-ssl --insecure --connect-timeout 5 -u "${FTP_USER}:${FTP_PASS}" "$BASE_FTP/" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Log "ERROR: No se pudo conectar al FTP $FTP_SERVER" Red
    Log "  Verifica que vsftpd este corriendo en Linux." Yellow
    exit 1
}
Log "OK: FTP conectado." Green

# Crear estructura
Log "" White; Log "Creando carpetas en FTP ..." Cyan
CrearCarpeta "/http/Windows/Apache"
CrearCarpeta "/http/Windows/Nginx"
Log "OK: Estructura lista." Green

# ============================
# APACHE
# ============================
Log "" White
Log "========================================" White
Log "  1/2 - Apache Windows" White
Log "========================================" White

$apacheDest = "$TMPDIR\apache_win.zip"
$apacheUrls = @(
    "https://www.apachelounge.com/download/VS17/binaries/httpd-2.4.62-win64-VS17.zip",
    "https://archive.apache.org/dist/httpd/binaries/win32/httpd-2.4.58-win64-VS17.zip",
    "https://downloads.apache.org/httpd/binaries/win32/httpd-2.4.62-win64-VS17.zip"
)

$ok = $false
foreach ($url in $apacheUrls) {
    if (Descargar $url $apacheDest) { $ok = $true; break }
}

if ($ok) {
    SHA256 $apacheDest
    SubirFTP $apacheDest        "/http/Windows/Apache/apache_win.zip"
    SubirFTP "$apacheDest.sha256" "/http/Windows/Apache/apache_win.zip.sha256"
    Log "OK: Apache listo en FTP." Green
} else {
    Log "ERROR: No se pudo descargar Apache." Red
    Log "  Descargalo manualmente de: https://www.apachelounge.com/download/" Yellow
    Log "  Guardalo como: $apacheDest" Yellow
    Log "  Y vuelve a ejecutar este script." Yellow
}

# ============================
# NGINX
# ============================
Log "" White
Log "========================================" White
Log "  2/2 - Nginx Windows" White
Log "========================================" White

$nginxDest = "$TMPDIR\nginx_win.zip"
$nginxUrls = @(
    "https://nginx.org/download/nginx-1.26.1.zip",
    "https://nginx.org/download/nginx-1.24.0.zip",
    "https://nginx.org/download/nginx-1.22.1.zip"
)

$ok = $false
foreach ($url in $nginxUrls) {
    if (Descargar $url $nginxDest) { $ok = $true; break }
}

if ($ok) {
    SHA256 $nginxDest
    SubirFTP $nginxDest        "/http/Windows/Nginx/nginx_win.zip"
    SubirFTP "$nginxDest.sha256" "/http/Windows/Nginx/nginx_win.zip.sha256"
    Log "OK: Nginx listo en FTP." Green
} else {
    Log "ERROR: No se pudo descargar Nginx." Red
    Log "  Descargalo manualmente de: https://nginx.org/en/download.html" Yellow
    Log "  Guardalo como: $nginxDest" Yellow
    Log "  Y vuelve a ejecutar este script." Yellow
}

# ============================
# RESULTADO
# ============================
Log "" White
Log "========================================" White
Log "  RESULTADO:" White
Log "========================================" White
Log "  FTP: $FTP_SERVER" White
Log "  /http/Windows/Apache/ -> apache_win.zip" Green
Log "  /http/Windows/Nginx/  -> nginx_win.zip" Green
Log "" White
Log "Ahora ejecuta: powershell -ExecutionPolicy Bypass -File orquestador_windows.ps1" Cyan
Log "" White