#!/bin/bash
set -e

# ============================================
# K3S AGENT INITIALIZATION SCRIPT
# ============================================
# Este script se ejecuta automáticamente cuando
# se crea una instancia del grupo de autoscaling
# convirtiendo cada instancia en un worker K3s
# ============================================

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

log "=== Iniciando configuración del agente K3s ==="

# ============================================
# OBTENER METADATA (Pasados como template variables)
# ============================================

K3S_TOKEN="${k3s_token}"
SERVER_IP="${server_ip}"
PROJECT_ID="${project_id}"

log "Configuración recibida:"
log "  - Servidor K3s: $SERVER_IP"
log "  - Proyecto GCP: $PROJECT_ID"

# ============================================
# ACTUALIZAR SISTEMA
# ============================================

log "Actualizando sistema operativo..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confold"

# ============================================
# INSTALAR PAQUETES NECESARIOS
# ============================================

log "Instalando paquetes necesarios..."
apt-get install -y \
    curl \
    wget \
    nfs-common \
    ca-certificates \
    gnupg \
    lsb-release \
    apt-transport-https

# ============================================
# INSTALAR GCLOUD CLI
# ============================================

log "Instalando Google Cloud SDK..."
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
    tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -

apt-get update -y
apt-get install -y google-cloud-cli

log "✓ Google Cloud SDK instalado"

# ============================================
# INSTALAR DOCKER
# ============================================

log "Instalando Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

systemctl enable docker
systemctl start docker

docker --version || error "Docker no se instaló correctamente"

log "✓ Docker instalado correctamente"

# ============================================
# CONFIGURAR DOCKER PARA GCR
# ============================================

log "Configurando Docker para Google Container Registry..."

# Configurar Docker credential helper para GCR
gcloud auth configure-docker gcr.io --quiet

# Crear configuración adicional de Docker
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

# Reiniciar Docker para aplicar cambios
systemctl restart docker

log "✓ Docker configurado para GCR"

# ============================================
# ESPERAR A QUE EL SERVIDOR K3S ESTÉ DISPONIBLE
# ============================================

log "Verificando disponibilidad del servidor K3s en $SERVER_IP:6443..."
timeout=300
elapsed=0

until curl -k -s https://$SERVER_IP:6443 >/dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
        error "Servidor K3s no disponible después de $timeout segundos"
        error "No se puede unir este nodo al cluster"
        exit 1
    fi
    log "Servidor K3s no responde aún, esperando... ($elapsed/$timeout segundos)"
    sleep 10
    elapsed=$((elapsed + 10))
done

log "✓ Servidor K3s accesible en $SERVER_IP:6443"

# ============================================
# INSTALAR K3S AGENT
# ============================================

log "Instalando K3s agent y uniéndose al cluster..."
curl -sfL https://get.k3s.io | K3S_URL="https://$SERVER_IP:6443" \
    K3S_TOKEN="$K3S_TOKEN" \
    INSTALL_K3S_EXEC="--node-label=role=worker" \
    sh -

# ============================================
# ESPERAR A QUE EL AGENTE ESTÉ LISTO
# ============================================

log "Esperando a que el agente K3s esté listo..."
sleep 30

# Verificar que el servicio esté corriendo
if systemctl is-active --quiet k3s-agent; then
    log "✓ Servicio k3s-agent está corriendo"
else
    error "El servicio k3s-agent no está corriendo"
    systemctl status k3s-agent --no-pager
    journalctl -u k3s-agent -n 50 --no-pager
    exit 1
fi

# ============================================
# DESCARGAR IMÁGENES DOCKER DESDE GCR
# ============================================

log "Descargando imágenes Docker desde GCR..."

# Esperar un momento para asegurar que Docker esté completamente listo
sleep 5

# Lista de imágenes a descargar
IMAGES=(
    "gcr.io/${PROJECT_ID}/coarlumini-database:latest"
    "gcr.io/${PROJECT_ID}/coarlumini-backend:latest"
    "gcr.io/${PROJECT_ID}/coarlumini-frontend:latest"
)

# Descargar cada imagen
for image in "${IMAGES[@]}"; do
    log "Descargando $image..."

    # Intentar descargar hasta 3 veces
    max_retries=3
    retry=0

    while [ $retry -lt $max_retries ]; do
        if docker pull "$image" 2>&1 | tee /tmp/docker-pull.log; then
            log "✓ Imagen descargada: $image"
            break
        else
            retry=$((retry + 1))
            if [ $retry -lt $max_retries ]; then
                log "⚠ Intento $retry falló, reintentando..."
                sleep 10
            else
                log "⚠ No se pudo descargar $image después de $max_retries intentos"
                log "⚠ Los pods usarán imagePullPolicy para descargar cuando sea necesario"
            fi
        fi
    done
done

# Verificar imágenes descargadas
log "Imágenes Docker locales:"
docker images | grep coarlumini || log "⚠ No se encontraron imágenes de coarlumini localmente"

log "✓ Proceso de descarga de imágenes completado"

# ============================================
# CONFIGURAR HEALTH CHECK CON NGINX
# ============================================

log "Configurando endpoint de health check con nginx..."
apt-get install -y nginx

# Obtener información de la instancia
INSTANCE_NAME=$(hostname)
ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $4}')
INTERNAL_IP=$(hostname -I | awk '{print $1}')

# Crear página de estado
cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>K3s Agent - Coarlumini</title>
    <style>
        body {
            font-family: 'Arial', sans-serif;
            margin: 40px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .container {
            background: rgba(255, 255, 255, 0.1);
            padding: 30px;
            border-radius: 10px;
            backdrop-filter: blur(10px);
        }
        h1 { margin-top: 0; }
        .info { background: rgba(0, 0, 0, 0.2); padding: 15px; border-radius: 5px; margin: 10px 0; }
        .status { color: #4ade80; font-weight: bold; }
        .detail { color: #60a5fa; }
    </style>
</head>
<body>
    <div class="container">
        <h1>⚡ K3s Worker Node - Coarlumini Cluster</h1>
        <div class="info">
            <p><strong>Status:</strong> <span class="status">Running</span></p>
            <p><strong>Node:</strong> <span class="detail">$INSTANCE_NAME</span></p>
            <p><strong>Role:</strong> K3s Worker (Agent)</p>
            <p><strong>Zone:</strong> <span class="detail">$ZONE</span></p>
            <p><strong>Internal IP:</strong> <span class="detail">$INTERNAL_IP</span></p>
            <p><strong>Connected to:</strong> <span class="detail">$SERVER_IP</span></p>
            <p><strong>Cluster:</strong> Coarlumini Production</p>
        </div>
        <hr style="border-color: rgba(255,255,255,0.2);">
        <p><small>Este nodo ejecuta workloads de la aplicación Coarlumini</small></p>
    </div>
</body>
</html>
EOF

systemctl enable nginx
systemctl start nginx

log "✓ Nginx health check configurado en puerto 80"

# ============================================
# OPTIMIZACIONES PARA K3S
# ============================================

log "Aplicando optimizaciones para K3s..."

# Aumentar límites de archivos
cat >> /etc/sysctl.conf <<EOF

# K3s optimizations
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
net.ipv4.ip_forward = 1
EOF

sysctl -p

# ============================================
# CREAR SCRIPT DE INFORMACIÓN
# ============================================

cat > /usr/local/bin/node-info <<'INFO_SCRIPT'
#!/bin/bash
echo "=========================================="
echo "K3S WORKER NODE - COARLUMINI CLUSTER"
echo "=========================================="
echo ""
echo "Node: $(hostname)"
echo "Internal IP: $(hostname -I | awk '{print $1}')"
echo "Status: $(systemctl is-active k3s-agent)"
echo ""
echo "K3s Agent Version:"
k3s --version | head -n1
echo ""
echo "Docker Version:"
docker --version
echo ""
echo "Imágenes Docker locales:"
docker images | grep coarlumini || echo "No hay imágenes de coarlumini"
echo ""
echo "=========================================="
echo ""
echo "💡 Este nodo es un worker del cluster K3s"
echo "   Los pods de Coarlumini pueden ejecutarse aquí"
echo ""
echo "Para ver logs del agente:"
echo "  journalctl -u k3s-agent -f"
echo ""
echo "=========================================="
INFO_SCRIPT

chmod +x /usr/local/bin/node-info

# ============================================
# MENSAJE DE BIENVENIDA
# ============================================

cat > /etc/motd <<'MOTD'

╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ⚡  K3S WORKER NODE - COARLUMINI CLUSTER  ⚡               ║
║                                                              ║
║   Este nodo ejecuta workloads del cluster Kubernetes        ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

   Ejecuta: node-info para ver información del nodo

MOTD

# ============================================
# FINALIZACIÓN
# ============================================

log "=== ✓ Agente K3s configurado correctamente ==="
log "=== Nodo unido al cluster exitosamente ==="
log "=== Servidor maestro: $SERVER_IP ==="
log "=== Este nodo está listo para ejecutar pods ==="

# Guardar información de inicialización
cat > /root/init-info.txt <<EOF
Inicialización completada: $(date)
Servidor K3s: $SERVER_IP
Project ID: $PROJECT_ID
Node name: $(hostname)
Internal IP: $(hostname -I | awk '{print $1}')
Zone: $ZONE
K3s version: $(k3s --version | head -n1)
Docker version: $(docker --version)
Status: $(systemctl is-active k3s-agent)
EOF

log "Información guardada en /root/init-info.txt"

exit 0
