#!/bin/bash
# ============================
# CONFIGURACIÓN
# ============================
FTP_USER="usuario"
FTP_HOME="/home/usuario"
TMPDIR="/tmp/instaladores"
mkdir -p "$TMPDIR"
cd "$TMPDIR" || exit 1

# ============================
# VALIDAR ROOT
# ============================
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ejecuta como root (sudo bash poblar_ftp.sh)"
  exit 1
fi

# ============================
# VERIFICAR DEPENDENCIAS
# ============================
for PKG in curl sha256sum; do
  if ! command -v "$PKG" &>/dev/null; then
    echo "⚙ Instalando $PKG..."
    apt-get install -y "$PKG" > /dev/null 2>&1
  fi
done

# ============================
# VERIFICAR QUE EL USUARIO EXISTA
# ============================
if ! id "$FTP_USER" &>/dev/null; then
  echo "⚠ El usuario '$FTP_USER' no existe. Creándolo..."
  useradd -m -s /bin/false "$FTP_USER"
  if [ $? -eq 0 ]; then
    echo "✅ Usuario '$FTP_USER' creado."
  else
    echo "❌ No se pudo crear el usuario '$FTP_USER'. Verifica permisos."
    exit 1
  fi
fi

# Recalcular FTP_HOME por si acaba de ser creado
FTP_HOME=$(getent passwd "$FTP_USER" | cut -d: -f6)
echo "📁 Directorio home del FTP: $FTP_HOME"

# ============================
# CREAR ESTRUCTURA DE CARPETAS
# ============================
echo "📁 Creando estructura de carpetas en el FTP..."
mkdir -p "$FTP_HOME/http/Linux/Apache"
mkdir -p "$FTP_HOME/http/Windows/Tomcat"
echo "✅ Carpetas creadas."

# ============================
# FUNCIÓN: COPIAR AL FTP
# ============================
copiar_ftp(){
  local ARCHIVO="$1"
  local DESTINO="$2"
  cp "$ARCHIVO" "$FTP_HOME/$DESTINO/$ARCHIVO"
  if [ $? -eq 0 ]; then
    echo "✅ $ARCHIVO → $FTP_HOME/$DESTINO/"
  else
    echo "❌ Error copiando $ARCHIVO"
  fi
}

# ============================
# FUNCIÓN: GENERAR SHA256
# ============================
generar_sha256(){
  sha256sum "$1" > "$1.sha256"
  echo "🔐 SHA256 generado: $1.sha256"
}

# ============================
# 1) APACHE .DEB
# ============================
echo ""
echo "========================================"
echo "  1/2 — Descargando Apache 2.4 (.deb)"
echo "========================================"

# Asegurarse de que apt esté actualizado antes de descargar
echo "⚙ Actualizando índice de paquetes..."
apt-get update -qq 2>&1 | tail -3

apt-get download apache2 2>/dev/null
APACHE_DEB=$(ls apache2_*.deb 2>/dev/null | head -1)

if [ -z "$APACHE_DEB" ]; then
  echo "⚠ apt-get download falló. Intentando con apt-cache + descarga manual..."

  # Fallback: instalar temporalmente y extraer el .deb del cache de apt
  apt-get install --download-only apache2 -y > /dev/null 2>&1
  APACHE_DEB_CACHE=$(find /var/cache/apt/archives/ -name "apache2_*.deb" 2>/dev/null | head -1)

  if [ -n "$APACHE_DEB_CACHE" ]; then
    cp "$APACHE_DEB_CACHE" "$TMPDIR/apache2_downloaded.deb"
    APACHE_DEB="apache2_downloaded.deb"
    echo "✅ Apache obtenido desde caché APT: $APACHE_DEB"
  else
    echo "❌ No se pudo obtener el .deb de Apache. Verifica conectividad a internet."
    echo "   Puedes intentar manualmente: apt-get install -y apache2 && dpkg-repack apache2"
  fi
fi

if [ -n "$APACHE_DEB" ]; then
  cp "$APACHE_DEB" apache_2.4.deb 2>/dev/null || mv "$APACHE_DEB" apache_2.4.deb
  generar_sha256 "apache_2.4.deb"
  copiar_ftp "apache_2.4.deb"        "http/Linux/Apache"
  copiar_ftp "apache_2.4.deb.sha256" "http/Linux/Apache"
  echo "✅ Apache listo."
fi

# ============================
# 2) TOMCAT .EXE / .MSI
# ============================
echo ""
echo "========================================"
echo "  2/2 — Descargando Tomcat 10 (.exe)"
echo "========================================"

# URLs espejo alternativas (dlcdn puede fallar por restricciones de red)
TOMCAT_URLS=(
  "https://downloads.apache.org/tomcat/tomcat-10/v10.1.39/bin/apache-tomcat-10.1.39.exe"
  "https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.39/bin/apache-tomcat-10.1.39.exe"
  "https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.39/bin/apache-tomcat-10.1.39.exe"
)

DESCARGADO=0
for URL in "${TOMCAT_URLS[@]}"; do
  echo "⬇ Intentando: $URL"
  curl -L --connect-timeout 10 --max-time 120 --progress-bar -o tomcat_10.exe "$URL" 2>/dev/null

  if [ -f "tomcat_10.exe" ] && [ -s "tomcat_10.exe" ]; then
    DESCARGADO=1
    echo "✅ Tomcat descargado desde: $URL"
    break
  else
    rm -f tomcat_10.exe
    echo "⚠ Falló: $URL"
  fi
done

# Renombrar a .msi para mantener compatibilidad con el orquestador
if [ $DESCARGADO -eq 1 ]; then
  mv tomcat_10.exe tomcat_10.msi
  generar_sha256 "tomcat_10.msi"
  copiar_ftp "tomcat_10.msi"        "http/Windows/Tomcat"
  copiar_ftp "tomcat_10.msi.sha256" "http/Windows/Tomcat"
  echo "✅ Tomcat listo."
else
  echo "❌ No se pudo descargar Tomcat desde ningún espejo."
  echo "   Descárgalo manualmente desde: https://tomcat.apache.org/download-10.cgi"
  echo "   y colócalo como: $FTP_HOME/http/Windows/Tomcat/tomcat_10.msi"
fi

# ============================
# PERMISOS — con validación
# ============================
echo ""
echo "⚙ Aplicando permisos..."
chown -R "$FTP_USER":"$FTP_USER" "$FTP_HOME/http" 2>/dev/null
if [ $? -ne 0 ]; then
  echo "⚠ No se pudo asignar propietario '$FTP_USER'. Aplicando solo permisos de lectura."
fi
chmod -R 755 "$FTP_HOME/http"
echo "✅ Permisos aplicados."

# ============================
# VERIFICAR RESULTADO
# ============================
echo ""
echo "========================================"
echo "  ESTRUCTURA FINAL EN EL FTP:"
echo "========================================"
find "$FTP_HOME/http" -type f | sort
echo "========================================"
echo "✅ FTP poblado. Ya puedes usar orquestador.sh"
echo ""