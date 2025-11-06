#!/bin/bash
set -e

# ============================================
# CLEAN AND REDEPLOY SCRIPT
# ============================================
# Este script limpia todo y reinicia el deployment
# desde cero cuando hay problemas
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
warning "  LIMPIEZA Y REDEPLOYMENT COMPLETO"
echo "=========================================="
echo ""
echo "⚠️  ADVERTENCIA: Este script:"
echo "   • Destruirá toda la infraestructura actual"
echo "   • Eliminará todas las instancias"
echo "   • Borrará los datos de los pods"
echo "   • Recreará todo desde cero"
echo ""
echo "Proyecto: $PROJECT_ID"
echo "Zona: $ZONE"
echo ""
echo "=========================================="
echo ""

# Confirmación
read -p "¿Estás seguro de continuar? (escribe 'SI' para continuar): " confirm

if [ "$confirm" != "SI" ]; then
    log "Cancelado por el usuario"
    exit 0
fi

# ============================================
# PASO 1: DESTRUIR INFRAESTRUCTURA ACTUAL
# ============================================

log "Paso 1: Destruyendo infraestructura actual..."

cd "$(dirname "$0")/.."

# Verificar si Terraform/Tofu está inicializado
if command -v tofu &> /dev/null; then
    TF_CMD="tofu"
elif command -v terraform &> /dev/null; then
    TF_CMD="terraform"
else
    error "❌ Ni terraform ni tofu están instalados"
    exit 1
fi

log "Usando: $TF_CMD"

# Intentar destroy normal
log "Ejecutando $TF_CMD destroy..."
$TF_CMD destroy -auto-approve -var-file="terraform.tfvars" || {
    warning "⚠ Destroy falló, intentando forzar eliminación manual..."

    # Eliminar instancias manualmente
    log "Eliminando instancias manualmente..."

    # Eliminar master
    gcloud compute instances delete $K3S_SERVER_NAME --zone=$ZONE --quiet 2>/dev/null || true

    # Eliminar workers
    WORKERS=$(gcloud compute instances list --filter="name:k3s-agent-*" --format="value(name)" 2>/dev/null || true)
    if [ -n "$WORKERS" ]; then
        echo "$WORKERS" | xargs -I {} gcloud compute instances delete {} --zone=$ZONE --quiet 2>/dev/null || true
    fi

    # Eliminar instance group manager
    gcloud compute instance-group-managers delete web-group-manager --zone=$ZONE --quiet 2>/dev/null || true

    # Eliminar autoscaler
    gcloud compute autoscalers delete web-autoscaler --zone=$ZONE --quiet 2>/dev/null || true

    # Eliminar instance template
    TEMPLATES=$(gcloud compute instance-templates list --filter="name:k3s-agent-template-*" --format="value(name)" 2>/dev/null || true)
    if [ -n "$TEMPLATES" ]; then
        echo "$TEMPLATES" | xargs -I {} gcloud compute instance-templates delete {} --quiet 2>/dev/null || true
    fi

    warning "⚠ Limpieza manual completada, algunos recursos pueden quedar"
}

success "✓ Infraestructura destruida"

# ============================================
# PASO 2: LIMPIAR ARCHIVOS LOCALES
# ============================================

log "Paso 2: Limpiando archivos locales..."

# Eliminar archivos de estado de Terraform
rm -f terraform.tfstate
rm -f terraform.tfstate.backup
rm -f .terraform.lock.hcl
rm -f k3s-config.yaml
rm -f deployment-info.txt

# Eliminar directorio .terraform si existe
if [ -d ".terraform" ]; then
    rm -rf .terraform
fi

success "✓ Archivos locales limpiados"

# ============================================
# PASO 3: LIMPIAR BUCKETS DE GCS
# ============================================

log "Paso 3: Limpiando buckets de Google Cloud Storage..."

# Buscar y eliminar buckets del proyecto
BUCKETS=$(gsutil ls -p $PROJECT_ID 2>/dev/null | grep "k8s" || true)

if [ -n "$BUCKETS" ]; then
    log "Eliminando buckets encontrados..."
    echo "$BUCKETS" | while read bucket; do
        log "Eliminando bucket: $bucket"
        gsutil -m rm -r "$bucket" 2>/dev/null || true
    done
    success "✓ Buckets eliminados"
else
    log "No se encontraron buckets para eliminar"
fi

# ============================================
# PASO 4: VERIFICAR LIMPIEZA
# ============================================

log "Paso 4: Verificando que todo fue eliminado..."

# Verificar instancias
REMAINING_INSTANCES=$(gcloud compute instances list --filter="name:(k3s-master OR k3s-agent)" --format="value(name)" 2>/dev/null || true)

if [ -n "$REMAINING_INSTANCES" ]; then
    warning "⚠ Aún hay instancias que no fueron eliminadas:"
    echo "$REMAINING_INSTANCES"
else
    success "✓ No hay instancias restantes"
fi

# ============================================
# PASO 5: ESPERAR PROPAGACIÓN
# ============================================

log "Paso 5: Esperando propagación de cambios (30 segundos)..."
sleep 30

success "✓ Limpieza completada"

# ============================================
# PASO 6: REDEPLOYMENT
# ============================================

echo ""
log "=========================================="
log "INICIANDO REDEPLOYMENT DESDE CERO"
log "=========================================="
echo ""

# Preguntar si continuar con el deployment
read -p "¿Deseas iniciar el deployment ahora? (S/n): " deploy_now

if [ "$deploy_now" = "n" ] || [ "$deploy_now" = "N" ]; then
    log "Limpieza completada. Deployment cancelado."
    echo ""
    echo "Para deployar manualmente después:"
    echo "  cd autoscaling-demo"
    echo "  ./scripts/full-deploy.sh"
    echo ""
    exit 0
fi

# Ejecutar deployment completo
log "Iniciando deployment automático..."

if [ -f "./scripts/full-deploy.sh" ]; then
    chmod +x ./scripts/full-deploy.sh
    ./scripts/full-deploy.sh
else
    error "❌ No se encontró el script full-deploy.sh"
    echo ""
    echo "Deployment manual:"
    echo "  1. Construir imágenes: ./scripts/build-and-push.sh"
    echo "  2. Inicializar Terraform: $TF_CMD init"
    echo "  3. Aplicar infraestructura: $TF_CMD apply -auto-approve"
    echo ""
    exit 1
fi

# ============================================
# FINALIZACIÓN
# ============================================

echo ""
echo "=========================================="
success "✓✓✓ LIMPIEZA Y REDEPLOYMENT COMPLETADOS ✓✓✓"
echo "=========================================="
echo ""
echo "🎉 El sistema ha sido limpiado y redesplegado"
echo ""
echo "📝 Próximos pasos:"
echo "   1. Verifica el estado: ./scripts/diagnose.sh"
echo "   2. Accede a la aplicación usando las IPs mostradas"
echo "   3. Monitorea los logs si hay problemas"
echo ""
echo "=========================================="
echo ""

exit 0
