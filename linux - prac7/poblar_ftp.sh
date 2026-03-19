#!/bin/bash
# ============================================================
#   POBLAR FTP - LINUX
#   Apache, Nginx, Tomcat (HTTP) y vsftpd (FTP)
#   Ejecutar como root en el servidor Linux
#   bash poblar_ftp_linux.sh
# ============================================================

FTP_ROOT="/srv/ftp"
TMP_DIR="/tmp/versiones_linux"
COLOR_OK="\e[32m"
COLOR_INFO="\e[36m"
COLOR_WARN="\e[33m"
COLOR_ERR="\e[31m"
COLOR_RESET="\e[0m"

mkdir -p "$TMP_DIR"
mkdir -p "$FTP_ROOT/http/Linux/Apache"
mkdir -p "$FTP_ROOT/http/Linux/Nginx"
mkdir -p "$FTP_ROOT/http/Linux/Tomcat"
mkdir -p "$FTP_ROOT/ftp/Linux/vsftpd"

log()  { echo -e "${COLOR_INFO}  $1${COLOR_RESET}"; }
ok()   { echo -e "${COLOR_OK}  OK: $1${COLOR_RESET}"; }
warn() { echo -e "${COLOR_WARN}  AVISO: $1${COLOR_RESET}"; }
err()  { echo -e "${COLOR_ERR}  ERROR: $1${COLOR_RESET}"; }

# ============================================================
#   SHA256
# ============================================================
sha256file() {
    local f="$1"
    local nombre
    nombre=$(basename "$f")
    sha256sum "$f" | awk "{print \$1\"  $nombre\"}" > "$f.sha256"
    log "SHA256: $nombre.sha256"
}

# ============================================================
#   DESCARGAR
# ============================================================
bajar() {
    local url="$1"
    local dest="$2"

    if [ -f "$dest" ] && [ "$(stat -c%s "$dest")" -gt 10000 ]; then
        ok "Ya existe: $(basename $dest)"
        return 0
    fi

    log "Descargando: $url"

    wget -q --no-check-certificate --timeout=60 --tries=3 -O "$dest" "$url" 2>/dev/null
    if [ -f "$dest" ] && [ "$(stat -c%s "$dest")" -gt 10000 ]; then
        ok "$(basename $dest) - $(du -sh $dest | cut -f1)"
        return 0
    fi
    rm -f "$dest"

    curl -L --insecure -A "Mozilla/5.0" --connect-timeout 30 --max-time 600 \
        --retry 2 -o "$dest" "$url" 2>/dev/null
    if [ -f "$dest" ] && [ "$(stat -c%s "$dest")" -gt 10000 ]; then
        ok "$(basename $dest) - $(du -sh $dest | cut -f1)"
        return 0
    fi
    rm -f "$dest"

    err "No se pudo descargar: $(basename $dest)"
    return 1
}

# ============================================================
#   COPIAR Y SHA256
# ============================================================
copiar() {
    local src="$1"
    local dst_dir="$2"
    local nombre="$3"

    if [ ! -f "$src" ]; then
        warn "No encontrado: $src"
        return
    fi
    cp "$src" "$dst_dir/$nombre"
    sha256file "$dst_dir/$nombre"
    ok "Copiado: $nombre"
}

# ============================================================
#   LINUX - APACHE (4 versiones tar.gz)
# ============================================================
echo ""
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"
echo -e "${COLOR_INFO}  Linux - Apache (4 versiones)         ${COLOR_RESET}"
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"

APACHE_VERS=(
    "https://archive.apache.org/dist/httpd/httpd-2.4.54.tar.gz|apache_2.4.54_linux.tar.gz"
    "https://archive.apache.org/dist/httpd/httpd-2.4.56.tar.gz|apache_2.4.56_linux.tar.gz"
    "https://archive.apache.org/dist/httpd/httpd-2.4.57.tar.gz|apache_2.4.57_linux.tar.gz"
    "https://archive.apache.org/dist/httpd/httpd-2.4.58.tar.gz|apache_2.4.58_linux.tar.gz"
)

for entry in "${APACHE_VERS[@]}"; do
    url="${entry%%|*}"
    nombre="${entry##*|}"
    echo ""
    echo -e "${COLOR_WARN}Apache $nombre:${COLOR_RESET}"
    dest="$TMP_DIR/$nombre"

    if bajar "$url" "$dest"; then
        copiar "$dest" "$FTP_ROOT/http/Linux/Apache" "$nombre"
    else
        warn "Intentando obtener .deb desde repositorio del sistema..."
        cd /tmp
        apt-get download apache2 2>/dev/null
        DEB_FILE=$(ls apache2_*.deb 2>/dev/null | head -1)
        if [ -n "$DEB_FILE" ]; then
            DST_NAME="${nombre%.tar.gz}.deb"
            mv "$DEB_FILE" "$FTP_ROOT/http/Linux/Apache/$DST_NAME"
            sha256file "$FTP_ROOT/http/Linux/Apache/$DST_NAME"
            ok "Obtenido como .deb: $DST_NAME"
        else
            err "No se pudo obtener Apache $nombre"
        fi
    fi
done

# ============================================================
#   LINUX - NGINX (4 versiones tar.gz)
# ============================================================
echo ""
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"
echo -e "${COLOR_INFO}  Linux - Nginx (4 versiones)          ${COLOR_RESET}"
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"

NGINX_VERS=(
    "https://nginx.org/download/nginx-1.22.1.tar.gz|nginx_1.22.1_linux.tar.gz"
    "https://nginx.org/download/nginx-1.24.0.tar.gz|nginx_1.24.0_linux.tar.gz"
    "https://nginx.org/download/nginx-1.26.1.tar.gz|nginx_1.26.1_linux.tar.gz"
    "https://nginx.org/download/nginx-1.26.2.tar.gz|nginx_1.26.2_linux.tar.gz"
)

for entry in "${NGINX_VERS[@]}"; do
    url="${entry%%|*}"
    nombre="${entry##*|}"
    echo ""
    echo -e "${COLOR_WARN}Nginx $nombre:${COLOR_RESET}"
    dest="$TMP_DIR/$nombre"

    if bajar "$url" "$dest"; then
        copiar "$dest" "$FTP_ROOT/http/Linux/Nginx" "$nombre"
    else
        warn "Intentando obtener .deb desde repositorio del sistema..."
        cd /tmp
        apt-get download nginx 2>/dev/null
        DEB_FILE=$(ls nginx_*.deb 2>/dev/null | head -1)
        if [ -n "$DEB_FILE" ]; then
            DST_NAME="${nombre%.tar.gz}.deb"
            mv "$DEB_FILE" "$FTP_ROOT/http/Linux/Nginx/$DST_NAME"
            sha256file "$FTP_ROOT/http/Linux/Nginx/$DST_NAME"
            ok "Obtenido como .deb: $DST_NAME"
        else
            err "No se pudo obtener Nginx $nombre"
        fi
    fi
done

# ============================================================
#   LINUX - TOMCAT (4 versiones tar.gz)
# ============================================================
echo ""
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"
echo -e "${COLOR_INFO}  Linux - Tomcat (4 versiones)         ${COLOR_RESET}"
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"

TOMCAT_VERS=(
    "https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.82/bin/apache-tomcat-9.0.82.tar.gz|tomcat_9.0.82_linux.tar.gz"
    "https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.85/bin/apache-tomcat-9.0.85.tar.gz|tomcat_9.0.85_linux.tar.gz"
    "https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.16/bin/apache-tomcat-10.1.16.tar.gz|tomcat_10.1.16_linux.tar.gz"
    "https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.18/bin/apache-tomcat-10.1.18.tar.gz|tomcat_10.1.18_linux.tar.gz"
)

for entry in "${TOMCAT_VERS[@]}"; do
    url="${entry%%|*}"
    nombre="${entry##*|}"
    echo ""
    echo -e "${COLOR_WARN}Tomcat $nombre:${COLOR_RESET}"
    dest="$TMP_DIR/$nombre"

    if bajar "$url" "$dest"; then
        copiar "$dest" "$FTP_ROOT/http/Linux/Tomcat" "$nombre"
    else
        err "No se pudo obtener $nombre"
    fi
done

# ============================================================
#   LINUX - VSFTPD (4 versiones info .txt)
# ============================================================
echo ""
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"
echo -e "${COLOR_INFO}  Linux - vsftpd (4 versiones info)    ${COLOR_RESET}"
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"

declare -A VSFTPD_INFO
VSFTPD_INFO["vsftpd_3.0.3"]="Ubuntu 18.04 / Ubuntu 20.04"
VSFTPD_INFO["vsftpd_3.0.5_ubuntu22"]="Ubuntu 22.04"
VSFTPD_INFO["vsftpd_3.0.5_deb11"]="Debian 11 (Bullseye)"
VSFTPD_INFO["vsftpd_3.0.5_deb12"]="Debian 12 (Bookworm)"

for ver in "${!VSFTPD_INFO[@]}"; do
    sistema="${VSFTPD_INFO[$ver]}"
    archivo="$FTP_ROOT/ftp/Linux/vsftpd/${ver}_install.txt"
    cat > "$archivo" << EOF
Version    : $ver
Sistema    : $sistema
Comando    : sudo apt-get install vsftpd -y
Config     : /etc/vsftpd.conf
Servicio   : systemctl enable vsftpd && systemctl start vsftpd
SSL/TLS    : ssl_enable=YES en /etc/vsftpd.conf
Nota       : vsftpd se instala desde repositorios del sistema operativo.
EOF
    sha256file "$archivo"
    ok "$ver creado"
done

# ============================================================
#   PERMISOS
# ============================================================
echo ""
log "Aplicando permisos..."
chown -R ftp:ftp "$FTP_ROOT" 2>/dev/null || chown -R nobody:nogroup "$FTP_ROOT" 2>/dev/null
chmod -R 755 "$FTP_ROOT"
ok "Permisos aplicados."

# ============================================================
#   RESUMEN
# ============================================================
echo ""
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"
echo -e "${COLOR_INFO}  RESULTADO LINUX                      ${COLOR_RESET}"
echo -e "${COLOR_INFO}========================================${COLOR_RESET}"
echo ""

find "$FTP_ROOT/http/Linux" "$FTP_ROOT/ftp/Linux" \
    -type f ! -name "*.sha256" | sort | \
    while read -r f; do
        size=$(du -sh "$f" 2>/dev/null | cut -f1)
        printf "  %-60s %s\n" "${f/$FTP_ROOT/}" "$size"
    done

echo ""
echo -e "${COLOR_OK}OK: Estructura Linux lista en $FTP_ROOT${COLOR_RESET}"
echo ""
echo -e "${COLOR_INFO}Estructura:${COLOR_RESET}"
echo "  $FTP_ROOT/http/Linux/Apache/  -> apache_x.x.xx_linux.tar.gz"
echo "  $FTP_ROOT/http/Linux/Nginx/   -> nginx_x.xx.x_linux.tar.gz"
echo "  $FTP_ROOT/http/Linux/Tomcat/  -> tomcat_x.x.xx_linux.tar.gz"
echo "  $FTP_ROOT/ftp/Linux/vsftpd/   -> vsftpd_x.x.x_install.txt"