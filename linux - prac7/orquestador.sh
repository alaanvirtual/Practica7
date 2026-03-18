#!/bin/bash
# ============================================================
#   ORQUESTADOR FINAL - PRÁCTICA 7
#   Autor: Infraestructura de Despliegue Profesional
#   Dominio: reprobados.com
#   Versión: 2.2
# ============================================================

# ============================
# CONFIGURACIÓN GLOBAL
# ============================
FTP_USER="usuario"
FTP_PASS="1234"
FTP_SERVER="192.168.100.1"
BASE_FTP="ftp://$FTP_SERVER"
DOMINIO="reprobados.com"
CERT_DIR="/etc/ssl/reprobados"
LOG_FILE="/var/log/orquestador.log"
RESUMEN=()

mkdir -p "$CERT_DIR"
touch "$LOG_FILE"

# ============================
# COLORES
# ============================
ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[1;34m'
CYAN='\033[0;36m'
BLANCO='\033[1;37m'
NC='\033[0m'

# ============================
# LOG
# ============================
log(){
  echo -e "$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# ============================
# VALIDAR ROOT
# ============================
if [ "$EUID" -ne 0 ]; then
  echo -e "${ROJO}❌ Ejecuta como root: sudo bash orquestador.sh${NC}"
  exit 1
fi

# ============================
# VERIFICAR DEPENDENCIAS
# ============================
verificar_deps(){
  log "${AZUL}⚙ Verificando dependencias...${NC}"
  for PKG in curl openssl sha256sum; do
    if ! command -v $PKG &>/dev/null; then
      log "${AMARILLO}  Instalando $PKG...${NC}"
      apt-get install -y $PKG > /dev/null 2>&1
    fi
  done
  log "${VERDE}✅ Dependencias listas.${NC}"
}

# ============================================================
#   MENÚ PRINCIPAL
# ============================================================
menu_principal(){
  clear
  echo -e "${AZUL}"
  echo "╔══════════════════════════════════════════╗"
  echo "║       ORQUESTADOR DE INSTALACIÓN         ║"
  echo "║          reprobados.com                  ║"
  echo "╠══════════════════════════════════════════╣"
  echo "║  1) Apache   → HTTPS puerto :443         ║"
  echo "║  2) Nginx    → HTTPS puerto :8443        ║"
  echo "║  3) Tomcat   → HTTPS puerto :8444        ║"
  echo "║  4) FTP (vsftpd) → FTPS puerto :21      ║"
  echo "║  5) Ver resumen de instalaciones         ║"
  echo "║  6) Salir                                ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"
  read -p "  Selecciona servicio: " SERV
}

# ============================================================
#   MENÚ ORIGEN
# ============================================================
menu_origen(){
  echo -e "${CYAN}"
  echo "  ┌──────────────────────────────┐"
  echo "  │  Origen de instalación:      │"
  echo "  │  1) WEB (apt repositorio)    │"
  echo "  │  2) FTP (repositorio privado)│"
  echo "  └──────────────────────────────┘"
  echo -e "${NC}"
  read -p "  Selecciona origen: " ORIGEN
}

# ============================================================
#   PROBAR CONEXIÓN FTP (con SSL)
# ============================================================
probar_ftp(){
  log "${AZUL}🔌 Probando conexión FTP a $FTP_SERVER...${NC}"
  curl --silent --fail --connect-timeout 5 \
       --ftp-ssl --insecure \
       -u "$FTP_USER:$FTP_PASS" \
       "$BASE_FTP/" > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    log "${ROJO}❌ No se pudo conectar al FTP ($FTP_SERVER).${NC}"
    log "${AMARILLO}  → IP configurada: $FTP_SERVER${NC}"
    log "${AMARILLO}  → Usuario: $FTP_USER${NC}"
    log "${AMARILLO}  → Verifica que vsftpd esté corriendo: systemctl status vsftpd${NC}"
    return 1
  fi
  log "${VERDE}✅ Conexión FTP exitosa.${NC}"
}

# ============================================================
#   LISTAR FTP (con SSL)
# ============================================================
listar_ftp(){
  curl --silent --ftp-pasv --ftp-ssl --insecure \
       -u "$FTP_USER:$FTP_PASS" "$1/" 2>/dev/null
}

# ============================================================
#   CONFIGURAR VSFTPD CORRECTAMENTE
# ============================================================
configurar_vsftpd_base(){
  log "${AZUL}⚙ Aplicando configuración base de vsftpd...${NC}"
  mkdir -p /var/run/vsftpd/empty

  cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
EOF
  log "${VERDE}✅ vsftpd.conf base aplicado.${NC}"
}

# ============================================================
#   ASEGURAR vsftpd.conf BASE (solo si no existe)
# ============================================================
asegurar_vsftpd_conf(){
  if [ ! -f /etc/vsftpd.conf ]; then
    log "${AMARILLO}⚠ vsftpd.conf no encontrado, creando...${NC}"
    configurar_vsftpd_base
  fi
}

# ============================================================
#   NAVEGACIÓN FTP DINÁMICA
# ============================================================
navegar_ftp(){
  probar_ftp || return 1

  CURRENT_URL="$BASE_FTP"

  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║     NAVEGADOR FTP INTERACTIVO        ║"
  echo "  ║  Escribe 'listo' para descargar aquí ║"
  echo "  ╚══════════════════════════════════════╝"
  echo -e "${NC}"

  for NIVEL in 1 2 3 4 5; do
    echo -e "${AMARILLO}📂 Contenido en: $CURRENT_URL${NC}"
    echo "  ──────────────────────────────────────"
    listar_ftp "$CURRENT_URL"
    echo "  ──────────────────────────────────────"
    read -p "  📁 Entrar a carpeta (o 'listo'): " ENTRADA

    [ "$ENTRADA" == "listo" ] && break

    ENTRADA=$(echo "$ENTRADA" | sed 's|^/||;s|/$||')
    CURRENT_URL="$CURRENT_URL/$ENTRADA"
  done

  echo -e "${AMARILLO}📦 Archivos disponibles en: $CURRENT_URL${NC}"
  echo "  ──────────────────────────────────────"
  listar_ftp "$CURRENT_URL"
  echo "  ──────────────────────────────────────"
  read -p "  📄 Nombre del archivo a descargar: " ARCHIVO

  [ -z "$ARCHIVO" ] && log "${ROJO}❌ No ingresaste un archivo.${NC}" && return 1

  ARCHIVO=$(echo "$ARCHIVO" | sed 's|^/||;s| ||g')
  cd /tmp

  log "${AZUL}⬇ Descargando $ARCHIVO...${NC}"
  curl --ftp-pasv --ftp-ssl --insecure \
       -u "$FTP_USER:$FTP_PASS" \
       -O "$CURRENT_URL/$ARCHIVO" 2>/dev/null

  if [ ! -f "/tmp/$ARCHIVO" ] || [ ! -s "/tmp/$ARCHIVO" ]; then
    log "${ROJO}❌ No se pudo descargar '$ARCHIVO'.${NC}"
    return 1
  fi

  log "${AZUL}⬇ Descargando checksum...${NC}"
  curl --ftp-pasv --ftp-ssl --insecure --silent \
       -u "$FTP_USER:$FTP_PASS" \
       -O "$CURRENT_URL/$ARCHIVO.sha256" 2>/dev/null

  if [ -f "/tmp/$ARCHIVO.sha256" ] && [ -s "/tmp/$ARCHIVO.sha256" ]; then
    verificar_hash "$ARCHIVO"
  else
    log "${AMARILLO}⚠ No se encontró .sha256, omitiendo verificación.${NC}"
  fi

  instalar_manual "$ARCHIVO"
}

# ============================================================
#   VALIDACIÓN DE INTEGRIDAD SHA256
# ============================================================
verificar_hash(){
  local ARCHIVO="$1"
  log "${AZUL}🔐 Verificando integridad SHA256 de $ARCHIVO...${NC}"
  cd /tmp
  sha256sum -c "$ARCHIVO.sha256"
  if [ $? -ne 0 ]; then
    log "${ROJO}❌ INTEGRIDAD FALLIDA — archivo corrupto o modificado.${NC}"
    RESUMEN+=("${ROJO}❌ Hash FALLIDO: $ARCHIVO${NC}")
    return 1
  fi
  log "${VERDE}✅ Integridad SHA256 verificada correctamente.${NC}"
  RESUMEN+=("${VERDE}✅ Hash OK: $ARCHIVO${NC}")
}

# ============================================================
#   INSTALACIÓN MANUAL (FTP)
# ============================================================
instalar_manual(){
  log "${AZUL}📦 Instalando $1...${NC}"
  case "$1" in
    *.deb)
      dpkg -i "/tmp/$1" 2>/dev/null
      apt-get install -f -y > /dev/null 2>&1
      ;;
    *.tar.gz)
      tar -xzf "/tmp/$1" -C /opt/
      log "${VERDE}✅ Extraído en /opt/${NC}"
      ;;
    *.msi|*.exe)
      log "${AMARILLO}⚠ Instalador Windows (.msi/.exe) no ejecutable en Linux.${NC}"
      ;;
    *.rpm)
      command -v rpm &>/dev/null && rpm -ivh "/tmp/$1" || log "${ROJO}❌ rpm no disponible.${NC}"
      ;;
    *)
      log "${AMARILLO}⚠ Formato no reconocido: $1${NC}"
      ;;
  esac
}

# ============================================================
#   INSTALACIÓN CON FALLBACK (WEB → CACHÉ → FTP)
# ============================================================
instalar_paquete(){
  local PKG="$1"
  local DEB_NOMBRE="$2"
  local FTP_RUTA="$3"

  # 1) apt normal
  log "${AZUL}⚙ Intentando instalar $PKG via apt...${NC}"
  apt-get install -y "$PKG" > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    log "${VERDE}✅ $PKG instalado via apt.${NC}"
    return 0
  fi
  log "${AMARILLO}⚠ apt falló.${NC}"

  # 2) apt --fix-missing
  apt-get install -y --fix-missing "$PKG" > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    log "${VERDE}✅ $PKG instalado via apt --fix-missing.${NC}"
    return 0
  fi

  # 3) Caché apt
  local DEB_CACHE
  DEB_CACHE=$(find /var/cache/apt/archives/ -name "${PKG}_*.deb" 2>/dev/null | head -1)
  if [ -n "$DEB_CACHE" ]; then
    log "${CYAN}📦 Encontrado en caché apt: $DEB_CACHE${NC}"
    dpkg -i "$DEB_CACHE" 2>/dev/null
    apt-get install -f -y > /dev/null 2>&1
    dpkg -l "$PKG" 2>/dev/null | grep -q "^ii" && return 0
  fi

  # 4) .deb local
  local DEB_LOCAL
  DEB_LOCAL=$(find /tmp /root /home /var/cache/apt/archives \
              -maxdepth 4 -name "${PKG}*.deb" 2>/dev/null | head -1)
  if [ -n "$DEB_LOCAL" ]; then
    log "${CYAN}📦 Encontrado localmente: $DEB_LOCAL${NC}"
    dpkg -i "$DEB_LOCAL" 2>/dev/null
    apt-get install -f -y > /dev/null 2>&1
    dpkg -l "$PKG" 2>/dev/null | grep -q "^ii" && return 0
  fi

  # 5) FTP privado
  if [ -n "$FTP_RUTA" ] && [ -n "$DEB_NOMBRE" ]; then
    log "${AZUL}⬇ Intentando desde FTP: $DEB_NOMBRE...${NC}"
    cd /tmp
    curl --ftp-pasv --ftp-ssl --insecure --connect-timeout 8 --max-time 60 \
         -u "$FTP_USER:$FTP_PASS" \
         -O "$BASE_FTP/$FTP_RUTA/$DEB_NOMBRE" 2>/dev/null
    if [ -f "/tmp/$DEB_NOMBRE" ] && [ -s "/tmp/$DEB_NOMBRE" ]; then
      log "${VERDE}✅ Descargado desde FTP: $DEB_NOMBRE${NC}"
      dpkg -i "/tmp/$DEB_NOMBRE" 2>/dev/null
      apt-get install -f -y > /dev/null 2>&1
      dpkg -l "$PKG" 2>/dev/null | grep -q "^ii" && return 0
    fi
    rm -f "/tmp/$DEB_NOMBRE"
    log "${AMARILLO}⚠ No se encontró $DEB_NOMBRE en el FTP.${NC}"
  fi

  log "${ROJO}❌ No se pudo instalar $PKG por ningún método.${NC}"
  return 1
}

# ============================================================
#   INSTALACIÓN WEB (APT)
# ============================================================
instalar_web(){
  log "${AZUL}🌐 Instalando $SERVICIO...${NC}"
  apt-get update -y > /dev/null 2>&1
  case "$SERVICIO" in
    Apache) instalar_paquete "apache2"  "apache_2.4.deb"  "http/Linux/Apache" ;;
    Nginx)  instalar_paquete "nginx"    "nginx.deb"       "http/Linux/Nginx"  ;;
    Tomcat) instalar_paquete "tomcat10" "tomcat_10.deb"   "http/Linux/Tomcat" ||
            instalar_paquete "tomcat9"  "tomcat_10.deb"   "http/Linux/Tomcat" ;;
    FTP)
      instalar_paquete "vsftpd" "vsftpd.deb" "http/Linux/FTP"
      asegurar_vsftpd_conf
      # Agregar /bin/false a shells permitidos
      grep -q "^/bin/false$" /etc/shells || echo "/bin/false" >> /etc/shells
      systemctl enable vsftpd 2>/dev/null
      systemctl start vsftpd
      ;;
  esac

  if [ $? -eq 0 ]; then
    log "${VERDE}✅ $SERVICIO instalado correctamente.${NC}"
    RESUMEN+=("${VERDE}✅ Instalación WEB OK: $SERVICIO${NC}")
  else
    log "${ROJO}❌ Error instalando $SERVICIO.${NC}"
    RESUMEN+=("${ROJO}❌ Instalación WEB FALLIDA: $SERVICIO${NC}")
  fi
}

# ============================================================
#   GENERACIÓN DE CERTIFICADO SSL AUTOFIRMADO
# ============================================================
generar_certificado(){
  local SERVICIO="$1"
  local CERT="$CERT_DIR/${SERVICIO,,}.crt"
  local KEY="$CERT_DIR/${SERVICIO,,}.key"

  log "${AZUL}🔑 Generando certificado SSL para $SERVICIO ($DOMINIO)...${NC}"

  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$KEY" \
    -out "$CERT" \
    -subj "/C=MX/ST=Sinaloa/L=LosMochis/O=Reprobados/OU=IT/CN=$DOMINIO" \
    > /dev/null 2>&1

  if [ $? -eq 0 ]; then
    log "${VERDE}✅ Certificado generado:${NC}"
    log "   CRT: $CERT"
    log "   KEY: $KEY"
    RESUMEN+=("${VERDE}✅ SSL generado: $SERVICIO → $CERT${NC}")
  else
    log "${ROJO}❌ Error generando certificado para $SERVICIO.${NC}"
    RESUMEN+=("${ROJO}❌ SSL FALLIDO: $SERVICIO${NC}")
    return 1
  fi

  chmod 600 "$KEY"
  chmod 644 "$CERT"
}

# ============================================================
#   SSL APACHE
# ============================================================
configurar_ssl_apache(){
  generar_certificado "Apache" || return

  CERT="$CERT_DIR/apache.crt"
  KEY="$CERT_DIR/apache.key"

  log "${AZUL}⚙ Configurando SSL en Apache (puerto 443)...${NC}"

  a2enmod ssl     > /dev/null 2>&1
  a2enmod rewrite > /dev/null 2>&1
  a2enmod headers > /dev/null 2>&1

  cat > /etc/apache2/sites-available/reprobados-ssl.conf <<EOF
<VirtualHost *:443>
    ServerName $DOMINIO
    ServerAlias www.$DOMINIO
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile $CERT
    SSLCertificateKeyFile $KEY

    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/reprobados_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/reprobados_ssl_access.log combined
</VirtualHost>
EOF

  cat > /etc/apache2/sites-available/reprobados-redirect.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMINIO
    ServerAlias www.$DOMINIO
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]
</VirtualHost>
EOF

  a2ensite reprobados-ssl.conf      > /dev/null 2>&1
  a2ensite reprobados-redirect.conf > /dev/null 2>&1
  a2dissite 000-default.conf        > /dev/null 2>&1

  apache2ctl configtest 2>&1 | grep -v "^$"
  systemctl restart apache2

  verificar_servicio "Apache" 443
}

# ============================================================
#   SSL NGINX
# ============================================================
configurar_ssl_nginx(){
  generar_certificado "Nginx" || return

  CERT="$CERT_DIR/nginx.crt"
  KEY="$CERT_DIR/nginx.key"

  log "${AZUL}⚙ Configurando SSL en Nginx (puerto 8443)...${NC}"

  rm -f /etc/nginx/sites-enabled/default

  cat > /etc/nginx/sites-available/reprobados-ssl <<EOF
server {
    listen 8080;
    server_name $DOMINIO www.$DOMINIO _;
    return 301 https://\$host:8443\$request_uri;
}

server {
    listen 8443 ssl;
    server_name $DOMINIO www.$DOMINIO _;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root /var/www/html;
    index index.html index.nginx-debian.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/reprobados-ssl \
         /etc/nginx/sites-enabled/reprobados-ssl

  nginx -t 2>&1
  systemctl restart nginx

  log "${VERDE}🌐 Nginx HTTPS disponible en: https://IP:8443${NC}"
  verificar_servicio "Nginx" 8443
}

# ============================================================
#   SSL TOMCAT
# ============================================================
configurar_ssl_tomcat(){
  generar_certificado "Tomcat" || return

  CERT="$CERT_DIR/tomcat.crt"
  KEY="$CERT_DIR/tomcat.key"

  TOMCAT_HOME=$(find /etc /opt -maxdepth 3 -name "server.xml" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
  [ -z "$TOMCAT_HOME" ] && TOMCAT_HOME="/etc/tomcat9"

  KEYSTORE="$CERT_DIR/tomcat.p12"
  log "${AZUL}⚙ Creando keystore para Tomcat...${NC}"
  openssl pkcs12 -export \
    -in "$CERT" -inkey "$KEY" \
    -out "$KEYSTORE" \
    -name reprobados \
    -passout pass:reprobados123 > /dev/null 2>&1

  log "${AZUL}⚙ Configurando conector HTTPS en Tomcat ($TOMCAT_HOME/server.xml)...${NC}"

  if ! grep -q "8444" "$TOMCAT_HOME/server.xml" 2>/dev/null; then
    python3 - <<PYEOF
import re

server_xml = "$TOMCAT_HOME/server.xml"

with open(server_xml, 'r') as f:
    content = f.read()

content = re.sub(r'<Connector port="8444".*?/>', '', content, flags=re.DOTALL)

connector = '''
    <Connector port="8444" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true"
               scheme="https" secure="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="$KEYSTORE"
                         certificateKeystorePassword="reprobados123"
                         type="RSA" />
        </SSLHostConfig>
    </Connector>
'''

content = content.replace('</Service>', connector + '</Service>')

with open(server_xml, 'w') as f:
    f.write(content)

print("OK")
PYEOF

    if [ $? -eq 0 ]; then
      log "${VERDE}✅ Conector HTTPS 8444 añadido a Tomcat correctamente.${NC}"
    else
      log "${ROJO}❌ Error editando server.xml${NC}"
      return 1
    fi
  else
    log "${AMARILLO}⚠ Conector 8444 ya existe en Tomcat.${NC}"
  fi

  systemctl restart tomcat9 2>/dev/null || systemctl restart tomcat10 2>/dev/null
  sleep 5
  log "${VERDE}🌐 Tomcat HTTPS disponible en: https://IP:8444${NC}"
  verificar_servicio "Tomcat" 8444
}

# ============================================================
#   SSL VSFTPD (FTPS)
# ============================================================
configurar_ssl_vsftpd(){
  generar_certificado "vsftpd" || return

  CERT="$CERT_DIR/vsftpd.crt"
  KEY="$CERT_DIR/vsftpd.key"

  log "${AZUL}⚙ Configurando FTPS en vsftpd...${NC}"

  # Instalar vsftpd si no está
  if ! command -v vsftpd &>/dev/null; then
    log "${AMARILLO}⚠ vsftpd no instalado. Instalando...${NC}"
    instalar_paquete "vsftpd" "vsftpd.deb" "http/Linux/FTP"
    if [ $? -ne 0 ]; then
      log "${ROJO}❌ No se pudo instalar vsftpd.${NC}"
      return
    fi
  fi

  # Agregar /bin/false a shells permitidos
  grep -q "^/bin/false$" /etc/shells || echo "/bin/false" >> /etc/shells

  # Quitar usuario de lista negra
  sed -i '/^usuario$/d' /etc/ftpusers 2>/dev/null

  # Escribir vsftpd.conf limpio y completo
  mkdir -p /var/run/vsftpd/empty
  cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100

# ── SSL/TLS (FTPS) ──────────────────────────
ssl_enable=YES
rsa_cert_file=$CERT
rsa_private_key_file=$KEY
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH
EOF

  systemctl enable vsftpd > /dev/null 2>&1
  systemctl restart vsftpd
  verificar_servicio "vsftpd/FTPS" 21
}

# ============================================================
#   VERIFICACIÓN DE SERVICIO
# ============================================================
verificar_servicio(){
  local NOMBRE="$1"
  local PUERTO="$2"

  sleep 2
  if ss -tlnp | grep -q ":$PUERTO "; then
    log "${VERDE}✅ $NOMBRE escuchando en puerto $PUERTO.${NC}"
    RESUMEN+=("${VERDE}✅ SSL ACTIVO: $NOMBRE → puerto $PUERTO${NC}")
  else
    log "${AMARILLO}⚠ $NOMBRE no detectado en puerto $PUERTO.${NC}"
    RESUMEN+=("${AMARILLO}⚠ SSL PENDIENTE: $NOMBRE → puerto $PUERTO${NC}")
  fi
}

# ============================================================
#   PREGUNTAR SSL
# ============================================================
preguntar_ssl(){
  echo ""
  read -p "  🔒 ¿Desea activar SSL/TLS en $SERVICIO? [S/N]: " ACTIVAR_SSL
  case "${ACTIVAR_SSL^^}" in
    S|SI|SÍ|YES|Y)
      case "$SERVICIO" in
        Apache) configurar_ssl_apache ;;
        Nginx)  configurar_ssl_nginx  ;;
        Tomcat) configurar_ssl_tomcat ;;
        FTP)    configurar_ssl_vsftpd ;;
      esac
      ;;
    *)
      log "${AMARILLO}⚠ SSL omitido para $SERVICIO.${NC}"
      RESUMEN+=("${AMARILLO}⚠ SSL omitido: $SERVICIO${NC}")
      ;;
  esac
}

# ============================================================
#   RESUMEN FINAL
# ============================================================
mostrar_resumen(){
  echo -e "${BLANCO}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║           RESUMEN DE INSTALACIONES               ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"

  if [ ${#RESUMEN[@]} -eq 0 ]; then
    echo -e "${AMARILLO}  Sin operaciones registradas aún.${NC}"
  else
    for ITEM in "${RESUMEN[@]}"; do
      echo -e "  $ITEM"
    done
  fi

  echo ""
  echo -e "${BLANCO}  Certificados generados en: $CERT_DIR${NC}"
  echo -e "${BLANCO}  Log completo en: $LOG_FILE${NC}"
  echo ""

  if ls "$CERT_DIR"/*.crt &>/dev/null; then
    echo -e "${CYAN}  Certificados SSL activos:${NC}"
    for CERT_FILE in "$CERT_DIR"/*.crt; do
      EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
      echo -e "  ${VERDE}  ✔ $(basename $CERT_FILE) — vence: $EXPIRY${NC}"
    done
  fi
  echo ""
}

# ============================================================
#   MAIN
# ============================================================
verificar_deps

echo -e "${CYAN}"
echo "  ┌──────────────────────────────────────────┐"
echo "  │  Configuración del servidor FTP          │"
echo "  │  (dejar vacío usa el valor por defecto)  │"
echo "  └──────────────────────────────────────────┘"
echo -e "${NC}"
read -p "  IP del servidor FTP [$FTP_SERVER]: " INPUT_IP
[ -n "$INPUT_IP" ] && FTP_SERVER="$INPUT_IP" && BASE_FTP="ftp://$FTP_SERVER"
read -p "  Usuario FTP [$FTP_USER]: " INPUT_USER
[ -n "$INPUT_USER" ] && FTP_USER="$INPUT_USER"
read -p "  Contraseña FTP [$FTP_PASS]: " INPUT_PASS
[ -n "$INPUT_PASS" ] && FTP_PASS="$INPUT_PASS"
log "${VERDE}✅ FTP configurado: $FTP_USER@$FTP_SERVER${NC}"

while true; do
  menu_principal

  case $SERV in
    1) SERVICIO="Apache" ;;
    2) SERVICIO="Nginx"  ;;
    3) SERVICIO="Tomcat" ;;
    4) SERVICIO="FTP"    ;;
    5) mostrar_resumen; continue ;;
    6) mostrar_resumen; log "${VERDE}👋 Saliendo...${NC}"; exit 0 ;;
    *) log "${ROJO}❌ Opción inválida.${NC}"; continue ;;
  esac

  menu_origen

  case $ORIGEN in
    1)
      instalar_web
      preguntar_ssl
      ;;
    2)
      navegar_ftp
      preguntar_ssl
      ;;
    *)
      log "${ROJO}❌ Origen inválido.${NC}"
      ;;
  esac

  echo ""
  read -p "  ↩ Presiona Enter para volver al menú..." _
done
