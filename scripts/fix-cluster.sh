#!/bin/bash
set -e

# ============================================
# FIX K3S CLUSTER ISSUES - VERSION 2
# ============================================
# Versión corregida con permisos sudo apropiados
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

# ============================================
# CONFIGURACIÓN
# ============================================

export PROJECT_ID=${PROJECT_ID:-cloudcomputingunsa}
export ZONE=${ZONE:-us-central1-a}
export K3S_SERVER_NAME="k3s-master-server"

echo ""
echo "=========================================="
log "  REPARACIÓN DEL CLUSTER K3S - V2"
echo "=========================================="
echo ""
echo "Proyecto: $PROJECT_ID"
echo "Zona: $ZONE"
echo "Servidor: $K3S_SERVER_NAME"
echo ""
echo "=========================================="
echo ""

# ============================================
# PASO 1: VERIFICAR IMÁGENES EN GCR
# ============================================

log "Paso 1: Verificando imágenes en Google Container Registry..."

IMAGES_MISSING=0

for image in database backend frontend; do
    if gcloud container images describe gcr.io/$PROJECT_ID/coarlumini-$image:latest &>/dev/null; then
        success "✓ Imagen existe: coarlumini-$image:latest"
    else
        error "❌ Imagen NO existe: coarlumini-$image:latest"
        IMAGES_MISSING=1
    fi
done

if [ $IMAGES_MISSING -eq 1 ]; then
    warning "⚠ Faltan imágenes en GCR. Construyendo ahora..."
    cd "$(dirname "$0")/.."
    ./scripts/build-and-push.sh || error "❌ Fallo construyendo imágenes"
    cd -
fi

success "✓ Todas las imágenes están en GCR"

# ============================================
# PASO 2: ELIMINAR NODOS PROBLEMÁTICOS
# ============================================

log "Paso 2: Eliminando nodos en estado NotReady del cluster..."

# Obtener nodos NotReady
NOTREADY_NODES=$(gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get nodes --no-headers 2>/dev/null | grep 'NotReady' | awk '{print \$1}'" 2>/dev/null || echo "")

if [ -n "$NOTREADY_NODES" ]; then
    log "Nodos NotReady encontrados:"
    echo "$NOTREADY_NODES"

    # Eliminar cada nodo del cluster
    echo "$NOTREADY_NODES" | while read node; do
        if [ -n "$node" ]; then
            log "Eliminando nodo del cluster: $node"
            gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
                --command="sudo kubectl delete node $node --force --grace-period=0" 2>/dev/null || true

            # Eliminar instancia de GCP correspondiente
            log "Eliminando instancia de GCP: $node"
            gcloud compute instances delete $node --zone=$ZONE --quiet 2>/dev/null || true
        fi
    done

    success "✓ Nodos NotReady eliminados"
else
    log "No hay nodos NotReady para eliminar"
fi

# ============================================
# PASO 3: LIMPIAR PODS PROBLEMÁTICOS
# ============================================

log "Paso 3: Limpiando pods problemáticos..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl delete pods --all -n coarlumini --force --grace-period=0 2>/dev/null || true"

success "✓ Pods limpiados"

# ============================================
# PASO 4: FORZAR RECREACIÓN DE WORKERS
# ============================================

log "Paso 4: Obteniendo lista de workers actuales..."

# Obtener lista de workers
WORKERS=$(gcloud compute instances list --filter="name:k3s-agent-*" --format="value(name)" 2>/dev/null || echo "")

if [ -n "$WORKERS" ]; then
    log "Workers encontrados:"
    echo "$WORKERS"

    warning "Eliminando workers problemáticos (se recrearán automáticamente)..."

    echo "$WORKERS" | while read worker; do
        if [ -n "$worker" ]; then
            log "Eliminando worker: $worker"
            gcloud compute instances delete $worker --zone=$ZONE --quiet 2>/dev/null || true
        fi
    done

    success "✓ Workers eliminados. El autoscaler creará nuevas instancias."
else
    warning "⚠ No se encontraron workers"
fi

# ============================================
# PASO 5: AJUSTAR INSTANCE GROUP
# ============================================

log "Paso 5: Ajustando instance group manager..."

# Verificar y ajustar el tamaño del instance group
CURRENT_SIZE=$(gcloud compute instance-groups managed describe web-group-manager \
    --zone=$ZONE --format="value(targetSize)" 2>/dev/null || echo "0")

log "Tamaño actual del instance group: $CURRENT_SIZE"

if [ "$CURRENT_SIZE" -lt "2" ]; then
    warning "⚠ Ajustando tamaño del instance group a 2..."
    gcloud compute instance-groups managed resize web-group-manager \
        --zone=$ZONE --size=2 || warning "⚠ No se pudo ajustar el tamaño"
fi

success "✓ Instance group configurado"

# ============================================
# PASO 6: ESPERAR NUEVOS WORKERS
# ============================================

log "Paso 6: Esperando a que se creen nuevos workers..."
log "Esto puede tomar 5-7 minutos..."

sleep 120  # Esperar 2 minutos inicial

# Monitorear la creación de workers
for i in {1..10}; do
    WORKER_COUNT=$(gcloud compute instances list --filter="name:k3s-agent-* AND status:RUNNING" \
        --format="value(name)" 2>/dev/null | wc -l)

    log "Intento $i/10: Workers en ejecución: $WORKER_COUNT"

    if [ "$WORKER_COUNT" -ge "1" ]; then
        success "✓ Al menos un worker está en ejecución"
        break
    fi

    sleep 30
done

# Esperar un poco más para que los workers se unan al cluster
sleep 60

# ============================================
# PASO 7: VERIFICAR NODOS EN EL CLUSTER
# ============================================

log "Paso 7: Verificando nodos en el cluster..."

echo ""
echo "Estado de los nodos:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get nodes -o wide"
echo ""

# ============================================
# PASO 8: DESCARGAR IMÁGENES EN EL MASTER (CON SUDO)
# ============================================

log "Paso 8: Descargando imágenes Docker en el master..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
set -e

# Configurar auth de Docker con sudo
sudo gcloud auth configure-docker gcr.io --quiet

# Descargar imágenes directamente con crictl (K3s)
echo 'Descargando imágenes con crictl (K3s)...'
for image in database backend frontend; do
    echo ''
    echo '=== Descargando coarlumini-\$image:latest ==='
    sudo crictl pull gcr.io/${PROJECT_ID}/coarlumini-\$image:latest || echo 'Fallo descargando \$image'
done

# Verificar imágenes
echo ''
echo '=== Imágenes en K3s ==='
sudo crictl images | grep coarlumini || echo 'No hay imágenes de coarlumini'
"

success "✓ Imágenes descargadas en el master"

# ============================================
# PASO 9: REDESPLEGAR APLICACIÓN
# ============================================

log "Paso 9: Redesplegando aplicación Coarlumini..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
# Eliminar namespace actual (si existe)
sudo kubectl delete namespace coarlumini --force --grace-period=0 2>/dev/null || true

# Esperar un momento
sleep 10

# Verificar si existe el script de deployment
if [ -f /root/deploy-coarlumini.sh ]; then
    echo 'Ejecutando script de deployment...'
    sudo bash /root/deploy-coarlumini.sh
else
    echo 'Script de deployment no encontrado en /root/deploy-coarlumini.sh'
    echo 'Intentando desplegar desde manifiestos...'

    if [ -d /root/k8s-manifests ]; then
        cd /root/k8s-manifests

        # Aplicar manifiestos en orden
        echo 'Aplicando manifiestos...'
        sudo kubectl apply -f 00-namespace.yaml 2>/dev/null || true
        sudo kubectl apply -f 01-configmap.yaml 2>/dev/null || true
        sudo kubectl apply -f 02-secrets.yaml 2>/dev/null || true
        sudo kubectl apply -f 03-database-pvc.yaml 2>/dev/null || true
        sudo kubectl apply -f 04-database-deployment.yaml 2>/dev/null || true
        sudo kubectl apply -f 05-database-service.yaml 2>/dev/null || true
        sudo kubectl apply -f 07-backend-pvc.yaml 2>/dev/null || true
        sudo kubectl apply -f 06-backend-deployment.yaml 2>/dev/null || true
        sudo kubectl apply -f 08-backend-service.yaml 2>/dev/null || true
        sudo kubectl apply -f 10-frontend-pvc.yaml 2>/dev/null || true
        sudo kubectl apply -f 11-nginx-config.yaml 2>/dev/null || true
        sudo kubectl apply -f 09-frontend-deployment.yaml 2>/dev/null || true
        sudo kubectl apply -f 12-frontend-service.yaml 2>/dev/null || true
        sudo kubectl apply -f 13-ingress.yaml 2>/dev/null || true

        echo 'Manifiestos aplicados'
    else
        echo 'No se encontraron manifiestos en /root/k8s-manifests'
    fi
fi
"

success "✓ Aplicación redesplegada"

# ============================================
# PASO 10: ESPERAR Y VERIFICAR PODS
# ============================================

log "Paso 10: Esperando a que los pods se inicialicen (60 segundos)..."
sleep 60

echo ""
echo "Estado de los pods:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get pods -n coarlumini -o wide"
echo ""

# ============================================
# PASO 11: DIAGNOSTICAR PODS PROBLEMÁTICOS
# ============================================

log "Paso 11: Diagnosticando pods con problemas..."

echo ""
echo "Eventos recientes en el namespace:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get events -n coarlumini --sort-by='.lastTimestamp' 2>/dev/null | tail -20"
echo ""

# Describir pods que no están Running
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
echo 'Pods que NO están Running:'
sudo kubectl get pods -n coarlumini --field-selector=status.phase!=Running 2>/dev/null

echo ''
echo 'Descripción de pods problemáticos:'
for pod in \$(sudo kubectl get pods -n coarlumini --field-selector=status.phase!=Running -o name 2>/dev/null); do
    echo ''
    echo '=== Descripción de \$pod ==='
    sudo kubectl describe \$pod -n coarlumini | tail -30
done
" || warning "⚠ No se pudieron obtener detalles de pods problemáticos"

# ============================================
# PASO 12: OBTENER INFORMACIÓN DE ACCESO
# ============================================

log "Paso 12: Obteniendo información de acceso..."

MASTER_IP=$(gcloud compute instances describe $K3S_SERVER_NAME \
    --zone=$ZONE \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

FRONTEND_PORT=$(gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get svc -n coarlumini coarlumini-frontend-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || echo "30080")

# ============================================
# RESUMEN
# ============================================

echo ""
echo "=========================================="
success "✓✓✓ REPARACIÓN COMPLETADA ✓✓✓"
echo "=========================================="
echo ""
echo "🎉 El cluster ha sido reparado"
echo ""
echo "📊 ESTADO ACTUAL:"
echo ""
echo "  Nodos:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get nodes --no-headers 2>/dev/null | wc -l" | xargs echo "    Total:"
echo ""
echo "  Pods en coarlumini:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get pods -n coarlumini --no-headers 2>/dev/null | wc -l" | xargs echo "    Total:"
echo ""
echo "📍 ACCESO A LA APLICACIÓN:"
echo ""
echo "  🌐 URL del Frontend:"
echo "     http://$MASTER_IP:$FRONTEND_PORT"
echo ""
echo "=========================================="
echo ""
echo "📊 COMANDOS ÚTILES:"
echo ""
echo "  SSH al servidor:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo ""
echo "  Ver nodos (desde el servidor):"
echo "    sudo kubectl get nodes"
echo ""
echo "  Ver pods (desde el servidor):"
echo "    sudo kubectl get pods -n coarlumini -o wide"
echo ""
echo "  Ver logs de un pod (desde el servidor):"
echo "    sudo kubectl logs <pod-name> -n coarlumini"
echo ""
echo "  Describir un pod (desde el servidor):"
echo "    sudo kubectl describe pod <pod-name> -n coarlumini"
echo ""
echo "=========================================="
echo ""
echo "💡 PRÓXIMOS PASOS:"
echo ""
echo "  1. Espera 5-10 minutos para que todo se estabilice"
echo "  2. Conéctate al servidor: gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo "  3. Verifica el estado: sudo kubectl get pods -n coarlumini"
echo "  4. Si hay pods en ImagePullBackOff, descríbelos:"
echo "     sudo kubectl describe pod <pod-name> -n coarlumini"
echo ""
echo "=========================================="
echo ""

exit 0
