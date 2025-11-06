#!/bin/bash
set -e

# ============================================
# FIX GCR PERMISSIONS FOR K3S CLUSTER
# ============================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

export PROJECT_ID=cloudcomputingunsa
export ZONE=us-central1-a
export K3S_SERVER_NAME="k3s-master-server"
export SERVICE_ACCOUNT="k3s-cluster-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo ""
log "=========================================="
log "  CONFIGURANDO PERMISOS DE GCR"
log "=========================================="
echo ""

# ============================================
# PASO 1: VERIFICAR SERVICE ACCOUNT
# ============================================

log "Paso 1: Verificando service account..."

if gcloud iam service-accounts describe $SERVICE_ACCOUNT --project=$PROJECT_ID &>/dev/null; then
    success "✓ Service account existe: $SERVICE_ACCOUNT"
else
    error "❌ Service account no existe: $SERVICE_ACCOUNT"
fi

# ============================================
# PASO 2: OTORGAR PERMISOS PARA GCR
# ============================================

log "Paso 2: Otorgando permisos para acceder a GCR..."

# Dar rol de Storage Object Viewer (necesario para leer de GCR)
log "Otorgando rol storage.objectViewer..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/storage.objectViewer" \
    --condition=None

# Dar rol específico de Container Registry
log "Otorgando rol containerregistry.ServiceAgent..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/containerregistry.ServiceAgent" \
    --condition=None 2>/dev/null || warning "⚠ Rol containerregistry.ServiceAgent no disponible (es opcional)"

success "✓ Permisos otorgados"

# ============================================
# PASO 3: VERIFICAR PERMISOS
# ============================================

log "Paso 3: Verificando permisos actuales..."

echo ""
echo "Roles del service account:"
gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:$SERVICE_ACCOUNT" \
    --format="table(bindings.role)"
echo ""

# ============================================
# PASO 4: CONFIGURAR CREDENCIALES EN EL MASTER
# ============================================

log "Paso 4: Configurando credenciales de Docker en el master..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
set -e

# Configurar gcloud auth para Docker con sudo
sudo gcloud auth configure-docker gcr.io --quiet

# Crear archivo de configuración de Docker para containerd/K3s
sudo mkdir -p /etc/rancher/k3s

# Crear configuración para crictl
sudo tee /etc/crictl.yaml > /dev/null <<EOF
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
image-endpoint: unix:///run/k3s/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo '✓ Configuración de Docker/crictl actualizada'

# Reiniciar K3s para aplicar cambios
echo 'Reiniciando K3s...'
sudo systemctl restart k3s
sleep 10

echo '✓ K3s reiniciado'
"

success "✓ Credenciales configuradas en el master"

# ============================================
# PASO 5: CONFIGURAR CREDENCIALES EN LOS WORKERS
# ============================================

log "Paso 5: Configurando credenciales en los workers..."

# Obtener lista de workers
WORKERS=$(gcloud compute instances list --filter="name:k3s-agent-* AND status:RUNNING" \
    --format="value(name)" 2>/dev/null || echo "")

if [ -n "$WORKERS" ]; then
    log "Workers encontrados:"
    echo "$WORKERS"

    echo "$WORKERS" | while read worker; do
        if [ -n "$worker" ]; then
            log "Configurando worker: $worker"

            gcloud compute ssh $worker --zone=$ZONE --command="
                # Configurar gcloud auth para Docker
                sudo gcloud auth configure-docker gcr.io --quiet

                # Crear configuración para crictl
                sudo tee /etc/crictl.yaml > /dev/null <<EOF
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
image-endpoint: unix:///run/k3s/containerd/containerd.sock
timeout: 10
debug: false
EOF

                # Reiniciar K3s agent
                sudo systemctl restart k3s-agent

                echo '✓ Worker $worker configurado'
            " 2>/dev/null || warning "⚠ No se pudo configurar worker $worker"
        fi
    done

    success "✓ Workers configurados"
else
    warning "⚠ No se encontraron workers en ejecución"
fi

# ============================================
# PASO 6: ESPERAR Y DESCARGAR IMÁGENES
# ============================================

log "Paso 6: Esperando que los servicios se reinicien (30 segundos)..."
sleep 30

log "Descargando imágenes en el master..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
set -e

echo 'Descargando imágenes con crictl...'
for image in database backend frontend; do
    echo ''
    echo '=== Descargando coarlumini-\$image:latest ==='
    sudo crictl pull gcr.io/${PROJECT_ID}/coarlumini-\$image:latest && echo '✓ \$image descargada' || echo '✗ Fallo descargando \$image'
done

echo ''
echo '=== Imágenes disponibles en K3s ==='
sudo crictl images | grep coarlumini || echo 'No hay imágenes de coarlumini'
"

# ============================================
# PASO 7: REDESPLEGAR PODS
# ============================================

log "Paso 7: Redesplegando pods de coarlumini..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
# Eliminar pods para que se recreen con las nuevas imágenes
sudo kubectl delete pods --all -n coarlumini --force --grace-period=0 2>/dev/null || true

echo 'Esperando 10 segundos...'
sleep 10

# Verificar estado
echo ''
echo '=== Estado de los pods ==='
sudo kubectl get pods -n coarlumini -o wide
"

# ============================================
# PASO 8: VERIFICAR ESTADO FINAL
# ============================================

log "Paso 8: Verificando estado final..."

sleep 30

echo ""
echo "Estado de los nodos:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get nodes"

echo ""
echo "Estado de los pods:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get pods -n coarlumini -o wide"

# ============================================
# RESUMEN
# ============================================

echo ""
echo "=========================================="
success "✓✓✓ PERMISOS DE GCR CONFIGURADOS ✓✓✓"
echo "=========================================="
echo ""
echo "🎉 Los permisos y credenciales han sido configurados"
echo ""
echo "💡 Próximos pasos:"
echo ""
echo "  1. Espera 2-3 minutos para que los pods se estabilicen"
echo ""
echo "  2. Verifica el estado de los pods:"
echo "     gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo "     sudo kubectl get pods -n coarlumini"
echo ""
echo "  3. Si los pods siguen en ImagePullBackOff, descríbelos:"
echo "     sudo kubectl describe pod <pod-name> -n coarlumini"
echo ""
echo "  4. Ver eventos:"
echo "     sudo kubectl get events -n coarlumini --sort-by='.lastTimestamp'"
echo ""
echo "=========================================="
echo ""

exit 0
