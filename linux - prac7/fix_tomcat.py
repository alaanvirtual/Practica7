#!/usr/bin/env python3
import re, os, sys

SERVER_XML = "/etc/tomcat10/server.xml"
KEYSTORE   = "/etc/ssl/reprobados/tomcat.p12"
PASS       = "reprobados123"

if os.geteuid() != 0:
    print("Ejecuta como root: sudo python3 fix_tomcat.py")
    sys.exit(1)

with open(SERVER_XML, 'r') as f:
    content = f.read()

# Quitar cualquier conector 8444 existente (viejo o nuevo)
content = re.sub(r'\s*<Connector port="8444".*?</Connector>', '', content, flags=re.DOTALL)
content = re.sub(r'\s*<Connector port="8444"[^>]*/>', '', content, flags=re.DOTALL)

connector = f"""
    <Connector port="8444"
               protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150"
               SSLEnabled="true"
               scheme="https"
               secure="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="{KEYSTORE}"
                         certificateKeystorePassword="{PASS}"
                         type="RSA" />
        </SSLHostConfig>
    </Connector>
"""

content = content.replace('</Service>', connector + '\n</Service>')

# Backup
os.system(f"cp {SERVER_XML} {SERVER_XML}.bak2")

with open(SERVER_XML, 'w') as f:
    f.write(content)

print("✅ server.xml actualizado correctamente.")
print("🔄 Reiniciando Tomcat10...")
os.system("systemctl restart tomcat10")
import time
time.sleep(10)
ret = os.system("ss -tlnp | grep 8444")
if ret == 0:
    print("✅ Tomcat escuchando en puerto 8444!")
else:
    print("⚠ Puerto 8444 aun no visible, revisa: sudo tail -20 /var/log/tomcat10/catalina.out")
