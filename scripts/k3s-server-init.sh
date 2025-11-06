#!/bin/bash
set -e

# ============================================
# K3S SERVER INITIALIZATION SCRIPT
# ============================================
# Este script se ejecuta automáticamente cuando
# se crea la instancia del servidor K3s (master)
# ============================================

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

log "=== Iniciando configuración del servidor K3s ==="

# ============================================
# OBTENER METADATA DE GCP
# ============================================

log "Obteniendo metadata de GCP..."
K3S_TOKEN=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/k3s-token)
DB_PASSWORD=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/db-password)
APP_KEY=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/app-key)
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/project-id)
BUCKET_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket-name)

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
    git \
    jq \
    nfs-common \
    ca-certificates \
    gnupg \
    lsb-release

# ============================================
# INSTALAR DOCKER
# ============================================

log "Instalando Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

# Iniciar Docker
systemctl enable docker
systemctl start docker

# Verificar instalación
docker --version || error "Docker no se instaló correctamente"

# ============================================
# CONFIGURAR DOCKER PARA GCR
# ============================================

log "Configurando Docker para Google Container Registry..."
gcloud auth configure-docker gcr.io --quiet

# ============================================
# INSTALAR K3S SERVER
# ============================================

log "Instalando K3s server (master node)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --write-kubeconfig-mode=644 \
    --disable=traefik \
    --tls-san=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip) \
    --bind-address=0.0.0.0 \
    --advertise-address=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip) \
    --node-taint=CriticalAddonsOnly=true:NoExecute" \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -

# ============================================
# ESPERAR A QUE K3S ESTÉ LISTO
# ============================================

log "Esperando a que K3s esté completamente listo..."
timeout=300
elapsed=0

until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    if [ $elapsed -ge $timeout ]; then
        error "K3s no se inició correctamente en $timeout segundos"
        journalctl -u k3s -n 50
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    log "Esperando K3s... ($elapsed/$timeout segundos)"
done

log "✓ K3s server está listo!"

# ============================================
# CONFIGURAR KUBECTL
# ============================================

log "Configurando kubectl para usuarios..."

# Para root
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /root/.kube/config

# Para usuario ubuntu (si existe)
if [ -d /home/ubuntu ]; then
    mkdir -p /home/ubuntu/.kube
    cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube
    chmod 600 /home/ubuntu/.kube/config
fi

# ============================================
# INSTALAR HELM
# ============================================

log "Instalando Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version || error "Helm no se instaló correctamente"

# ============================================
# INSTALAR NGINX INGRESS CONTROLLER
# ============================================

log "Instalando nginx ingress controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml

# Esperar a que el ingress controller esté listo
log "Esperando a que el ingress controller esté listo..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s || log "⚠ Timeout esperando ingress controller (puede seguir inicializándose)"

# ============================================
# CREAR NAMESPACE COARLUMINI
# ============================================

log "Creando namespace coarlumini..."
kubectl create namespace coarlumini || log "Namespace ya existe"

# ============================================
# DESCARGAR MANIFIESTOS K8S DESDE GCS
# ============================================

log "Descargando manifiestos de Kubernetes desde GCS..."
mkdir -p /root/k8s-manifests
gsutil -m cp -r "gs://${BUCKET_NAME}/*" /root/k8s-manifests/

log "✓ Manifiestos descargados: $(ls -1 /root/k8s-manifests/ | wc -l) archivos"

# ============================================
# CREAR SECRETS DE COARLUMINI
# ============================================

log "Creando secrets para Coarlumini..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: coarlumini-secrets
  namespace: coarlumini
type: Opaque
stringData:
  APP_KEY: "${APP_KEY}"
  DB_USERNAME: "coarlumini_user"
  DB_PASSWORD: "${DB_PASSWORD}"
  MAIL_PASSWORD: ""
  REDIS_PASSWORD: ""
EOF

log "✓ Secrets creados"

# ============================================
# CREAR CONFIGMAP DE COARLUMINI
# ============================================

log "Creando ConfigMap para Coarlumini..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coarlumini-config
  namespace: coarlumini
data:
  APP_PORT: "80"
  DB_HOST: "coarlumini-database-service"
  DB_PORT: "3306"
  DB_DATABASE: "coarlumini"
  FRONTEND_HOST: "coarlumini-frontend-service"
  APP_URL: "http://coarlumini-backend-service"
  APP_ENV: "production"
  APP_DEBUG: "false"
  CACHE_DRIVER: "file"
  SESSION_DRIVER: "file"
  QUEUE_CONNECTION: "sync"
  PROJECT_ID: "${PROJECT_ID}"
EOF

log "✓ ConfigMap creado"

# ============================================
# ACTUALIZAR MANIFIESTOS CON RUTAS DE GCR
# ============================================

log "Actualizando manifiestos con rutas de GCR..."
cd /root/k8s-manifests

# Actualizar imagen de database
sed -i "s|image: mysql:8.0|image: gcr.io/${PROJECT_ID}/coarlumini-database:latest|g" 04-database-deployment.yaml 2>/dev/null || true

# Actualizar imagen de backend
sed -i "s|image: gcr.io/cloudcomputingunsa/coarlumini-backend:latest|image: gcr.io/${PROJECT_ID}/coarlumini-backend:latest|g" 06-backend-deployment.yaml 2>/dev/null || true
sed -i "s|image: gcr.io/[^/]*/coarlumini-backend:latest|image: gcr.io/${PROJECT_ID}/coarlumini-backend:latest|g" 06-backend-deployment.yaml 2>/dev/null || true

# Actualizar imagen de frontend
sed -i "s|image: gcr.io/cloudcomputingunsa/coarlumini-frontend:latest|image: gcr.io/${PROJECT_ID}/coarlumini-frontend:latest|g" 09-frontend-deployment.yaml 2>/dev/null || true
sed -i "s|image: gcr.io/[^/]*/coarlumini-frontend:latest|image: gcr.io/${PROJECT_ID}/coarlumini-frontend:latest|g" 09-frontend-deployment.yaml 2>/dev/null || true
sed -i "s|coarlumini-frontend:late|coarlumini-frontend:latest|g" 09-frontend-deployment.yaml 2>/dev/null || true

# Cambiar storageClassName a local-path para K3s (ya debería estar en archivos base, pero por si acaso)
sed -i "s|storageClassName: standard-rwo|storageClassName: local-path|g" 03-database-pvc.yaml 2>/dev/null || true
sed -i "s|storageClassName: standard-rwo|storageClassName: local-path|g" 07-backend-pvc.yaml 2>/dev/null || true
sed -i "s|storageClassName: standard-rwo|storageClassName: local-path|g" 10-frontend-pvc.yaml 2>/dev/null || true

# Configurar imagePullPolicy como IfNotPresent para usar imágenes locales
for file in 04-database-deployment.yaml 06-backend-deployment.yaml 09-frontend-deployment.yaml; do
    if [ -f "$file" ]; then
        # Remover imagePullPolicy existente
        sed -i '/imagePullPolicy:/d' "$file"
        # Agregar IfNotPresent después de cada línea de image
        sed -i '/image: gcr.io/a\          imagePullPolicy: IfNotPresent' "$file"
    fi
done

log "✓ Manifiestos actualizados"

# ============================================
# DESCARGAR IMÁGENES DOCKER DESDE GCR
# ============================================

log "Descargando imágenes Docker desde GCR..."

# Autenticar Docker con GCR usando el service account
gcloud auth configure-docker gcr.io --quiet 2>/dev/null || log "⚠ No se pudo configurar docker auth"

# Descargar las tres imágenes
log "Descargando imagen de database..."
docker pull gcr.io/${PROJECT_ID}/coarlumini-database:latest 2>/dev/null || log "⚠ No se pudo descargar imagen de database"

log "Descargando imagen de backend..."
docker pull gcr.io/${PROJECT_ID}/coarlumini-backend:latest 2>/dev/null || log "⚠ No se pudo descargar imagen de backend"

log "Descargando imagen de frontend..."
docker pull gcr.io/${PROJECT_ID}/coarlumini-frontend:latest 2>/dev/null || log "⚠ No se pudo descargar imagen de frontend"

# Verificar imágenes descargadas
log "Imágenes Docker locales:"
docker images | grep coarlumini || log "⚠ No se encontraron imágenes de coarlumini"

log "✓ Imágenes Docker descargadas"

# ============================================
# CREAR SCRIPT DE DEPLOYMENT
# ============================================

log "Creando script de deployment de Coarlumini..."
cat > /root/deploy-coarlumini.sh <<'DEPLOY_SCRIPT'
#!/bin/bash
set -e

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Desplegando Coarlumini en Kubernetes ==="

cd /root/k8s-manifests

# Aplicar namespace y configuraciones
log "Aplicando namespace y configuraciones..."
kubectl apply -f 00-namespace.yaml 2>/dev/null || true
kubectl apply -f 01-configmap.yaml 2>/dev/null || true
kubectl apply -f 02-secrets.yaml 2>/dev/null || true
kubectl apply -f 11-nginx-config.yaml 2>/dev/null || true

# Aplicar PVCs
log "Creando volúmenes persistentes..."
kubectl apply -f 03-database-pvc.yaml
kubectl apply -f 07-backend-pvc.yaml 2>/dev/null || true
kubectl apply -f 10-frontend-pvc.yaml 2>/dev/null || true

# Desplegar base de datos
log "Desplegando base de datos MySQL..."
kubectl apply -f 04-database-deployment.yaml
kubectl apply -f 05-database-service.yaml

log "Esperando a que la base de datos esté lista (hasta 5 minutos)..."
kubectl wait --for=condition=ready pod \
    -l app=coarlumini-database \
    -n coarlumini \
    --timeout=300s || log "⚠ Timeout en database, continuando..."

# Desplegar backend
log "Desplegando backend Laravel..."
kubectl apply -f 06-backend-deployment.yaml
kubectl apply -f 08-backend-service.yaml

log "Esperando a que el backend esté listo (hasta 5 minutos)..."
kubectl wait --for=condition=ready pod \
    -l app=coarlumini-backend \
    -n coarlumini \
    --timeout=300s || log "⚠ Timeout en backend, continuando..."

# Desplegar frontend
log "Desplegando frontend Vue.js..."
kubectl apply -f 09-frontend-deployment.yaml
kubectl apply -f 12-frontend-service.yaml

log "Esperando a que el frontend esté listo (hasta 3 minutos)..."
kubectl wait --for=condition=ready pod \
    -l app=coarlumini-frontend \
    -n coarlumini \
    --timeout=180s || log "⚠ Timeout en frontend, continuando..."

# Aplicar Ingress
log "Configurando Ingress..."
kubectl apply -f 13-ingress.yaml 2>/dev/null || log "⚠ No se pudo aplicar Ingress"

# Aplicar HPA (Horizontal Pod Autoscaler)
log "Configurando Horizontal Pod Autoscaler..."
kubectl apply -f 14-horizontal-escalling.yaml 2>/dev/null || log "⚠ No se pudo aplicar HPA"

# Mostrar estado
log "=== Estado del deployment ==="
kubectl get all -n coarlumini

log "=== Deployment completado ==="
DEPLOY_SCRIPT

chmod +x /root/deploy-coarlumini.sh
log "✓ Script de deployment creado en /root/deploy-coarlumini.sh"

# ============================================
# CONFIGURAR HEALTH CHECK CON NGINX
# ============================================

log "Configurando health check endpoint con nginx..."
apt-get install -y nginx

# Crear página de estado
cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>K3s Server - Coarlumini</title>
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
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 K3s Master Server - Coarlumini Cluster</h1>
        <div class="info">
            <p><strong>Status:</strong> <span class="status">Running</span></p>
            <p><strong>Node:</strong> $(hostname)</p>
            <p><strong>Role:</strong> K3s Master (Control Plane)</p>
            <p><strong>Cluster:</strong> Coarlumini Production</p>
            <p><strong>Application:</strong> Laravel + Vue.js + MySQL</p>
        </div>
        <hr style="border-color: rgba(255,255,255,0.2);">
        <p><small>Este servidor controla el cluster K3s que ejecuta la aplicación Coarlumini</small></p>
    </div>
</body>
</html>
EOF

systemctl enable nginx
systemctl start nginx

log "✓ Nginx health check configurado"

# ============================================
# CREAR SCRIPT DE INFORMACIÓN
# ============================================

cat > /root/info.sh <<'INFO_SCRIPT'
#!/bin/bash
echo "=========================================="
echo "K3S SERVER - COARLUMINI CLUSTER"
echo "=========================================="
echo ""
echo "🔧 Comandos útiles:"
echo ""
echo "  Ver nodos del cluster:"
echo "    kubectl get nodes"
echo ""
echo "  Ver pods de Coarlumini:"
echo "    kubectl get pods -n coarlumini"
echo ""
echo "  Ver servicios:"
echo "    kubectl get svc -n coarlumini"
echo ""
echo "  Ver logs del backend:"
echo "    kubectl logs -l app=coarlumini-backend -n coarlumini -f"
echo ""
echo "  Ver logs del frontend:"
echo "    kubectl logs -l app=coarlumini-frontend -n coarlumini -f"
echo ""
echo "  Ver logs de la base de datos:"
echo "    kubectl logs -l app=coarlumini-database -n coarlumini -f"
echo ""
echo "  Desplegar/Redesplegar aplicación:"
echo "    sudo /root/deploy-coarlumini.sh"
echo ""
echo "  Escalar backend manualmente:"
echo "    kubectl scale deployment coarlumini-backend -n coarlumini --replicas=3"
echo ""
echo "  Reiniciar un componente:"
echo "    kubectl rollout restart deployment/coarlumini-backend -n coarlumini"
echo ""
echo "=========================================="
INFO_SCRIPT

chmod +x /root/info.sh

# ============================================
# MENSAJE DE BIENVENIDA EN SSH
# ============================================

cat > /etc/motd <<'MOTD'

╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   🚀  K3S MASTER SERVER - COARLUMINI CLUSTER  🚀             ║
║                                                              ║
║   Cluster Kubernetes ejecutando aplicación Coarlumini       ║
║   (Laravel + Vue.js + MySQL)                                 ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

   Ejecuta: /root/info.sh para ver comandos útiles

MOTD

# ============================================
# FINALIZACIÓN
# ============================================

log "=== ✓ Servidor K3s configurado correctamente ==="
log "=== El servidor está listo para recibir nodos worker ==="
log "=== Token K3s: [REDACTED] ==="
log "=== Para desplegar Coarlumini, ejecutar: /root/deploy-coarlumini.sh ==="

# Guardar información de inicialización
cat > /root/init-info.txt <<EOF
Inicialización completada: $(date)
Project ID: ${PROJECT_ID}
Bucket de manifiestos: ${BUCKET_NAME}
K3s version: $(k3s --version | head -n1)
Kubectl version: $(kubectl version --client --short 2>/dev/null || echo "N/A")
Helm version: $(helm version --short 2>/dev/null || echo "N/A")
EOF

log "Información guardada en /root/init-info.txt"

exit 0
