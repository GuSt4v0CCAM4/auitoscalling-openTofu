#!/bin/bash
set -e

# ============================================
# FIX GCR AUTHENTICATION - DEFINITIVO V3
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

echo ""
log "=========================================="
log "  SOLUCIÓN DEFINITIVA GCR V3"
log "=========================================="
echo ""

# ============================================
# PASO 1: CREAR SERVICE ACCOUNT KEY
# ============================================

log "Paso 1: Creando clave de service account..."

SA_NAME="k3s-cluster-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_FILE="gcr-key.json"

# Eliminar clave anterior si existe
rm -f $KEY_FILE

# Crear nueva clave
gcloud iam service-accounts keys create $KEY_FILE \
    --iam-account=$SA_EMAIL \
    --project=$PROJECT_ID

success "✓ Clave creada: $KEY_FILE"

# ============================================
# PASO 2: CREAR IMAGEPULLSECRET EN KUBERNETES
# ============================================

log "Paso 2: Creando ImagePullSecret en Kubernetes..."

# Copiar la clave al servidor K3s
gcloud compute scp $KEY_FILE ${K3S_SERVER_NAME}:/tmp/gcr-key.json --zone=$ZONE

# Crear el secret en Kubernetes
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
set -e

# Crear namespace si no existe
sudo kubectl create namespace coarlumini 2>/dev/null || true

# Eliminar secret anterior si existe
sudo kubectl delete secret gcr-json-key -n coarlumini 2>/dev/null || true

# Crear ImagePullSecret usando la clave del service account
sudo kubectl create secret docker-registry gcr-json-key \
    --docker-server=gcr.io \
    --docker-username=_json_key \
    --docker-password=\"\$(cat /tmp/gcr-key.json)\" \
    --docker-email=${SA_EMAIL} \
    -n coarlumini

echo '✓ ImagePullSecret creado'

# Limpiar clave temporal
rm -f /tmp/gcr-key.json
"

# Limpiar clave local
rm -f $KEY_FILE

success "✓ ImagePullSecret creado en Kubernetes"

# ============================================
# PASO 3: BUSCAR DIRECTORIO DE MANIFIESTOS
# ============================================

log "Paso 3: Buscando directorio de manifiestos..."

MANIFEST_DIR=$(gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
if sudo test -d /root/k8s-manifests; then
    echo '/root/k8s-manifests'
elif sudo test -d /home/*/k8s-manifests; then
    sudo find /home -name 'k8s-manifests' -type d 2>/dev/null | head -n1
elif sudo test -d /var/lib/k8s-manifests; then
    echo '/var/lib/k8s-manifests'
else
    echo ''
fi
" 2>/dev/null | tr -d '\r')

if [ -z "$MANIFEST_DIR" ]; then
    warning "⚠ No se encontró directorio de manifiestos en el servidor"
    log "Descargando manifiestos desde GCS bucket..."

    # Obtener nombre del bucket
    BUCKET_NAME=$(gcloud storage buckets list --project=$PROJECT_ID --format="value(name)" | grep "k8s" | head -n1)

    if [ -n "$BUCKET_NAME" ]; then
        log "Bucket encontrado: $BUCKET_NAME"

        gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
            sudo mkdir -p /root/k8s-manifests
            sudo gsutil -m cp -r gs://${BUCKET_NAME}/* /root/k8s-manifests/ 2>/dev/null || echo 'Error descargando desde GCS'
        "

        MANIFEST_DIR="/root/k8s-manifests"
        success "✓ Manifiestos descargados a $MANIFEST_DIR"
    else
        error "❌ No se encontró bucket de manifiestos. Usa los manifiestos desde el repo local."
        exit 1
    fi
else
    success "✓ Directorio de manifiestos encontrado: $MANIFEST_DIR"
fi

# ============================================
# PASO 4: ACTUALIZAR DEPLOYMENTS
# ============================================

log "Paso 4: Actualizando deployments para usar ImagePullSecret..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
set -e

MANIFEST_DIR='$MANIFEST_DIR'

echo 'Trabajando en directorio: \$MANIFEST_DIR'

# Listar archivos disponibles
echo 'Archivos en el directorio:'
sudo ls -la \$MANIFEST_DIR/*.yaml 2>/dev/null || echo 'No se encontraron archivos YAML'

# Función para actualizar deployment
update_deployment() {
    local file=\$1
    local name=\$2

    if sudo test -f \"\$MANIFEST_DIR/\$file\"; then
        echo \"Actualizando \$file...\"

        # Verificar si ya tiene imagePullSecrets
        if sudo grep -q 'imagePullSecrets' \"\$MANIFEST_DIR/\$file\"; then
            echo \"  -> Ya tiene imagePullSecrets configurado\"
        else
            echo \"  -> Agregando imagePullSecrets...\"

            # Crear backup
            sudo cp \"\$MANIFEST_DIR/\$file\" \"\$MANIFEST_DIR/\$file.backup\"

            # Usar sed para agregar imagePullSecrets
            sudo sed -i '/^    spec:\$/a\\      imagePullSecrets:\\n      - name: gcr-json-key' \"\$MANIFEST_DIR/\$file\"

            echo \"  -> imagePullSecrets agregado\"
        fi

        echo \"Contenido actualizado de \$file (primeras 50 líneas):\"
        sudo head -50 \"\$MANIFEST_DIR/\$file\"
    else
        echo \"⚠ Archivo no encontrado: \$MANIFEST_DIR/\$file\"
    fi
}

# Actualizar los tres deployments
update_deployment '04-database-deployment.yaml' 'database'
echo ''
update_deployment '06-backend-deployment.yaml' 'backend'
echo ''
update_deployment '09-frontend-deployment.yaml' 'frontend'

echo ''
echo '✓ Deployments actualizados'
"

success "✓ Deployments actualizados"

# ============================================
# PASO 5: APLICAR DEPLOYMENTS
# ============================================

log "Paso 5: Eliminando pods actuales y aplicando deployments..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
set -e

MANIFEST_DIR='$MANIFEST_DIR'

# Eliminar pods actuales para forzar recreación
echo 'Eliminando pods actuales...'
sudo kubectl delete pods --all -n coarlumini --force --grace-period=0 2>/dev/null || true

sleep 5

# Aplicar manifiestos en orden
echo 'Aplicando manifiestos desde \$MANIFEST_DIR...'

apply_manifest() {
    local file=\$1
    if sudo test -f \"\$MANIFEST_DIR/\$file\"; then
        echo \"Aplicando \$file...\"
        sudo kubectl apply -f \"\$MANIFEST_DIR/\$file\" 2>&1 || echo \"⚠ Error aplicando \$file\"
    else
        echo \"⚠ Archivo no encontrado: \$file\"
    fi
}

apply_manifest '00-namespace.yaml'
apply_manifest '01-configmap.yaml'
apply_manifest '02-secrets.yaml'
apply_manifest '03-database-pvc.yaml'
apply_manifest '04-database-deployment.yaml'
apply_manifest '05-database-service.yaml'
apply_manifest '06-backend-deployment.yaml'
apply_manifest '07-backend-pvc.yaml'
apply_manifest '08-backend-service.yaml'
apply_manifest '09-frontend-deployment.yaml'
apply_manifest '10-frontend-pvc.yaml'
apply_manifest '11-nginx-config.yaml'
apply_manifest '12-frontend-service.yaml'
apply_manifest '13-ingress.yaml'

echo ''
echo '✓ Todos los manifiestos aplicados'
"

success "✓ Deployments aplicados"

# ============================================
# PASO 6: ESPERAR Y VERIFICAR
# ============================================

log "Paso 6: Esperando a que los pods se inicialicen (60 segundos)..."
sleep 60

echo ""
echo "=========================================="
echo "ESTADO DE LOS PODS:"
echo "=========================================="
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get pods -n coarlumini -o wide"

echo ""
echo "=========================================="
echo "EVENTOS RECIENTES:"
echo "=========================================="
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get events -n coarlumini --sort-by='.lastTimestamp' | tail -20"

# ============================================
# PASO 7: DIAGNOSTICAR PODS PROBLEMÁTICOS
# ============================================

log "Paso 7: Diagnosticando pods problemáticos (si hay)..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
echo ''
echo 'Pods que NO están Running:'
sudo kubectl get pods -n coarlumini --field-selector=status.phase!=Running 2>/dev/null || echo '✓ Todos los pods están Running'

echo ''
echo 'Descripción de pods problemáticos (si hay):'
for pod in \$(sudo kubectl get pods -n coarlumini --field-selector=status.phase!=Running -o name 2>/dev/null); do
    if [ -n \"\$pod\" ]; then
        echo ''
        echo '========================================'
        echo \"Descripción de \$pod\"
        echo '========================================'
        sudo kubectl describe \$pod -n coarlumini | tail -40
    fi
done

# Verificar ImagePullSecret
echo ''
echo '========================================'
echo 'Verificando ImagePullSecret:'
echo '========================================'
sudo kubectl get secret gcr-json-key -n coarlumini -o jsonpath='{.metadata.name}' 2>/dev/null && echo ' - OK' || echo ' - ERROR: Secret no encontrado'
"

# ============================================
# PASO 8: OBTENER IP DE ACCESO
# ============================================

log "Paso 8: Obteniendo información de acceso..."

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
success "✓✓✓ CONFIGURACIÓN COMPLETADA ✓✓✓"
echo "=========================================="
echo ""
echo "🎉 ImagePullSecret configurado correctamente"
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
echo "  Ver estado de los pods:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command='sudo kubectl get pods -n coarlumini'"
echo ""
echo "  Ver detalles de un pod:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command='sudo kubectl describe pod <pod-name> -n coarlumini'"
echo ""
echo "  Ver logs de un pod:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command='sudo kubectl logs <pod-name> -n coarlumini'"
echo ""
echo "  SSH al servidor:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo ""
echo "=========================================="
echo ""
echo "💡 SIGUIENTE PASO:"
echo ""
echo "  Espera 2-3 minutos más y verifica el estado de los pods."
echo "  Si los pods aún tienen ImagePullBackOff, describe uno con:"
echo ""
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo "    sudo kubectl describe pod <pod-name> -n coarlumini"
echo ""
echo "=========================================="
echo ""

exit 0
