#!/bin/bash
# ============================================================
#   POBLAR FTP - PRÁCTICA 7
#   Crea estructura: /http/Linux/{Apache,Nginx,Tomcat,FTP}
#   Sin necesidad de internet (usa caché apt o binarios instalados)
# ============================================================

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
for PKG in curl sha256sum dpkg-repack; do
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
    echo "❌ No se pudo crear el usuario '$FTP_USER'."
    exit 1
  fi
fi

# Recalcular FTP_HOME
FTP_HOME=$(getent passwd "$FTP_USER" | cut -d: -f6)
echo "📁 Directorio home del FTP: $FTP_HOME"

# ============================
# CREAR ESTRUCTURA DE CARPETAS
# ============================
echo ""
echo "📁 Creando estructura de carpetas..."
mkdir -p "$FTP_HOME/http/Linux/Apache"
mkdir -p "$FTP_HOME/http/Linux/Nginx"
mkdir -p "$FTP_HOME/http/Linux/Tomcat"
mkdir -p "$FTP_HOME/http/Linux/FTP"
echo "✅ Carpetas creadas:"
echo "   $FTP_HOME/http/Linux/Apache"
echo "   $FTP_HOME/http/Linux/Nginx"
echo "   $FTP_HOME/http/Linux/Tomcat"
echo "   $FTP_HOME/http/Linux/FTP"

# ============================
# FUNCIÓN: COPIAR AL FTP
# ============================
copiar_ftp(){
  local ARCHIVO="$1"
  local DESTINO="$FTP_HOME/$2"
  cp "$TMPDIR/$ARCHIVO" "$DESTINO/$ARCHIVO"
  if [ $? -eq 0 ]; then
    echo "   ✅ $ARCHIVO → $DESTINO/"
  else
    echo "   ❌ Error copiando $ARCHIVO"
  fi
}

# ============================
# FUNCIÓN: GENERAR SHA256
# ============================
generar_sha256(){
  cd "$TMPDIR"
  sha256sum "$1" > "$1.sha256"
  echo "   🔐 SHA256: $1.sha256"
}

# ============================
# FUNCIÓN: OBTENER .DEB
# Intenta en orden: apt download → caché apt → dpkg-repack
# ============================
obtener_deb(){
  local PKG="$1"
  local NOMBRE_FINAL="$2"
  local DEB=""

  cd "$TMPDIR"

  # 1) apt-get download (necesita internet)
  apt-get download "$PKG" > /dev/null 2>&1
  DEB=$(ls ${PKG}_*.deb 2>/dev/null | head -1)

  # 2) Caché de apt en disco
  if [ -z "$DEB" ]; then
    DEB=$(find /var/cache/apt/archives/ -name "${PKG}_*.deb" 2>/dev/null | head -1)
    [ -n "$DEB" ] && cp "$DEB" "$TMPDIR/" && DEB=$(basename "$DEB")
  fi

  # 3) dpkg-repack (empaqueta el binario ya instalado)
  if [ -z "$DEB" ] && command -v dpkg-repack &>/dev/null; then
    if dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then
      echo "   ⚙ Empaquetando $PKG instalado con dpkg-repack..."
      cd "$TMPDIR"
      dpkg-repack "$PKG" > /dev/null 2>&1
      DEB=$(ls ${PKG}_*.deb 2>/dev/null | head -1)
    fi
  fi

  if [ -n "$DEB" ]; then
    cp "$TMPDIR/$DEB" "$TMPDIR/$NOMBRE_FINAL" 2>/dev/null || \
    mv "$TMPDIR/$DEB" "$TMPDIR/$NOMBRE_FINAL" 2>/dev/null
    echo "   ✅ Obtenido: $NOMBRE_FINAL"
    return 0
  else
    echo "   ❌ No se pudo obtener $PKG"
    return 1
  fi
}

# ============================
# ACTUALIZAR APT (si hay internet)
# ============================
echo ""
echo "⚙ Actualizando índice de paquetes (si hay internet)..."
apt-get update -qq 2>&1 | tail -1

# ============================================================
#   1) APACHE
# ============================================================
echo ""
echo "========================================"
echo "  1/4 — Apache 2.4 (.deb)"
echo "========================================"

if obtener_deb "apache2" "apache_2.4.deb"; then
  generar_sha256 "apache_2.4.deb"
  copiar_ftp "apache_2.4.deb"        "http/Linux/Apache"
  copiar_ftp "apache_2.4.deb.sha256" "http/Linux/Apache"
  echo "✅ Apache listo en FTP."
else
  echo "❌ Apache no disponible."
fi

# ============================================================
#   2) NGINX
# ============================================================
echo ""
echo "========================================"
echo "  2/4 — Nginx (.deb)"
echo "========================================"

if obtener_deb "nginx" "nginx.deb"; then
  generar_sha256 "nginx.deb"
  copiar_ftp "nginx.deb"        "http/Linux/Nginx"
  copiar_ftp "nginx.deb.sha256" "http/Linux/Nginx"
  echo "✅ Nginx listo en FTP."
else
  echo "❌ Nginx no disponible."
fi

# ============================================================
#   3) TOMCAT
# ============================================================
echo ""
echo "========================================"
echo "  3/4 — Tomcat (.deb)"
echo "========================================"

if obtener_deb "tomcat10" "tomcat_10.deb"; then
  generar_sha256 "tomcat_10.deb"
  copiar_ftp "tomcat_10.deb"        "http/Linux/Tomcat"
  copiar_ftp "tomcat_10.deb.sha256" "http/Linux/Tomcat"
  echo "✅ Tomcat listo en FTP."
elif obtener_deb "tomcat9" "tomcat_10.deb"; then
  generar_sha256 "tomcat_10.deb"
  copiar_ftp "tomcat_10.deb"        "http/Linux/Tomcat"
  copiar_ftp "tomcat_10.deb.sha256" "http/Linux/Tomcat"
  echo "✅ Tomcat9 listo en FTP."
else
  echo "❌ Tomcat no disponible."
fi

# ============================================================
#   4) VSFTPD
# ============================================================
echo ""
echo "========================================"
echo "  4/4 — vsftpd (.deb)"
echo "========================================"

if obtener_deb "vsftpd" "vsftpd.deb"; then
  generar_sha256 "vsftpd.deb"
  copiar_ftp "vsftpd.deb"        "http/Linux/FTP"
  copiar_ftp "vsftpd.deb.sha256" "http/Linux/FTP"
  echo "✅ vsftpd listo en FTP."
else
  echo "❌ vsftpd no disponible."
fi

# ============================
# PERMISOS
# ============================
echo ""
echo "⚙ Aplicando permisos..."
chown -R "$FTP_USER":"$FTP_USER" "$FTP_HOME/http" 2>/dev/null
chmod -R 755 "$FTP_HOME/http"
echo "✅ Permisos aplicados."

# ============================
# RESULTADO FINAL
# ============================
echo ""
echo "========================================"
echo "  ESTRUCTURA FINAL EN EL FTP:"
echo "========================================"
find "$FTP_HOME/http" -type f | sort
echo "========================================"
echo ""
echo "✅ FTP poblado. Conéctate con FileZilla:"
echo "   Host:      192.168.100.1"
echo "   Usuario:   $FTP_USER"
echo "   Contraseña: 1234"
echo "   Puerto:    21"
echo "   Protocolo: FTP explícito sobre TLS"
echo ""
