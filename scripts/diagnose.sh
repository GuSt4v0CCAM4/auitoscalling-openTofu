#!/bin/bash
set -e

# ============================================
# DIAGNOSTIC SCRIPT FOR K3S CLUSTER
# ============================================
# Este script diagnostica problemas comunes
# en el deployment de Coarlumini en K3s
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
echo "  DIAGNÓSTICO DEL CLUSTER K3S"
echo "=========================================="
echo ""
echo "Proyecto: $PROJECT_ID"
echo "Zona: $ZONE"
echo "Servidor: $K3S_SERVER_NAME"
echo ""
echo "=========================================="
echo ""

# ============================================
# 1. VERIFICAR CONECTIVIDAD CON GCP
# ============================================

log "1. Verificando conectividad con GCP..."

if ! gcloud compute instances describe $K3S_SERVER_NAME --zone=$ZONE &>/dev/null; then
    error "❌ No se puede encontrar la instancia $K3S_SERVER_NAME"
    echo "   Verifica que el servidor existe con:"
    echo "   gcloud compute instances list"
    exit 1
else
    success "✓ Instancia del servidor encontrada"
fi

# ============================================
# 2. VERIFICAR ESTADO DE LA INSTANCIA
# ============================================

log "2. Verificando estado de la instancia..."

INSTANCE_STATUS=$(gcloud compute instances describe $K3S_SERVER_NAME \
    --zone=$ZONE --format="get(status)")

if [ "$INSTANCE_STATUS" != "RUNNING" ]; then
    error "❌ La instancia no está en estado RUNNING (estado actual: $INSTANCE_STATUS)"
    exit 1
else
    success "✓ Instancia está RUNNING"
fi

# ============================================
# 3. VERIFICAR IPs
# ============================================

log "3. Verificando IPs..."

MASTER_INTERNAL_IP=$(gcloud compute instances describe $K3S_SERVER_NAME \
    --zone=$ZONE --format="get(networkInterfaces[0].networkIP)")

MASTER_EXTERNAL_IP=$(gcloud compute instances describe $K3S_SERVER_NAME \
    --zone=$ZONE --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

echo "   IP Interna: $MASTER_INTERNAL_IP"
echo "   IP Externa: $MASTER_EXTERNAL_IP"

if [ -z "$MASTER_EXTERNAL_IP" ]; then
    warning "⚠ No se encontró IP externa"
else
    success "✓ IPs obtenidas correctamente"
fi

# ============================================
# 4. VERIFICAR REGLAS DE FIREWALL
# ============================================

log "4. Verificando reglas de firewall..."

echo ""
echo "Reglas de firewall relevantes:"
gcloud compute firewall-rules list \
    --filter="name~(web|k3s)" \
    --format="table(name,direction,sourceRanges.list():label=SRC_RANGES,allowed[].map().firewall_rule().list():label=ALLOW)"

# Verificar regla específica para puerto 6443
FIREWALL_6443=$(gcloud compute firewall-rules list \
    --filter="allowed.ports:6443" \
    --format="value(name)" | head -n1)

if [ -n "$FIREWALL_6443" ]; then
    success "✓ Regla de firewall para puerto 6443 encontrada: $FIREWALL_6443"
else
    warning "⚠ No se encontró regla de firewall para puerto 6443"
    echo "   Esto puede causar problemas de conectividad al API server"
fi

# ============================================
# 5. VERIFICAR CONECTIVIDAD SSH
# ============================================

log "5. Verificando conectividad SSH..."

if gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="echo 'SSH OK'" &>/dev/null; then
    success "✓ Conectividad SSH funcionando"
else
    error "❌ No se puede conectar por SSH"
    echo "   Verifica las reglas de firewall y las claves SSH"
    exit 1
fi

# ============================================
# 6. VERIFICAR K3S EN EL MASTER
# ============================================

log "6. Verificando K3s en el master..."

K3S_STATUS=$(gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="systemctl is-active k3s 2>/dev/null" || echo "inactive")

if [ "$K3S_STATUS" = "active" ]; then
    success "✓ Servicio K3s está activo"
else
    error "❌ Servicio K3s no está activo (estado: $K3S_STATUS)"
    echo ""
    echo "Logs de K3s:"
    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
        --command="sudo journalctl -u k3s -n 50 --no-pager"
    exit 1
fi

# ============================================
# 7. VERIFICAR NODOS DEL CLUSTER
# ============================================

log "7. Verificando nodos del cluster..."

echo ""
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get nodes -o wide"
echo ""

NODE_COUNT=$(gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get nodes --no-headers 2>/dev/null | wc -l" || echo "0")

if [ "$NODE_COUNT" -gt "0" ]; then
    success "✓ Nodos encontrados: $NODE_COUNT"
else
    warning "⚠ No se encontraron nodos en el cluster"
fi

# ============================================
# 8. VERIFICAR IMÁGENES EN GCR
# ============================================

log "8. Verificando imágenes en Google Container Registry..."

echo ""
echo "Imágenes en GCR:"
gcloud container images list --repository=gcr.io/$PROJECT_ID 2>/dev/null || \
    warning "⚠ No se pudieron listar imágenes en GCR"

for image in frontend backend database; do
    if gcloud container images describe gcr.io/$PROJECT_ID/coarlumini-$image:latest &>/dev/null; then
        success "✓ Imagen encontrada: coarlumini-$image:latest"
    else
        error "❌ Imagen NO encontrada: coarlumini-$image:latest"
        echo "   Ejecuta: ./scripts/build-and-push.sh"
    fi
done

# ============================================
# 9. VERIFICAR IMÁGENES EN EL MASTER
# ============================================

log "9. Verificando imágenes Docker en el master..."

echo ""
echo "Imágenes en el master:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo crictl images | grep coarlumini || echo 'No hay imágenes de coarlumini'"
echo ""

# ============================================
# 10. VERIFICAR NAMESPACE COARLUMINI
# ============================================

log "10. Verificando namespace coarlumini..."

NAMESPACE_EXISTS=$(gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get namespace coarlumini --no-headers 2>/dev/null | wc -l" || echo "0")

if [ "$NAMESPACE_EXISTS" -gt "0" ]; then
    success "✓ Namespace 'coarlumini' existe"
else
    warning "⚠ Namespace 'coarlumini' no existe"
    echo "   Se creará durante el deployment"
fi

# ============================================
# 11. VERIFICAR PODS
# ============================================

log "11. Verificando pods en coarlumini..."

echo ""
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get pods -n coarlumini -o wide 2>/dev/null" || \
    warning "⚠ No se pudieron obtener los pods"
echo ""

# ============================================
# 12. VERIFICAR PVCS
# ============================================

log "12. Verificando PersistentVolumeClaims..."

echo ""
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get pvc -n coarlumini 2>/dev/null" || \
    warning "⚠ No se pudieron obtener los PVCs"
echo ""

# ============================================
# 13. VERIFICAR STORAGECLASS
# ============================================

log "13. Verificando StorageClasses..."

echo ""
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get storageclass"
echo ""

STORAGECLASS_EXISTS=$(gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get storageclass local-path --no-headers 2>/dev/null | wc -l" || echo "0")

if [ "$STORAGECLASS_EXISTS" -gt "0" ]; then
    success "✓ StorageClass 'local-path' existe (requerido para K3s)"
else
    error "❌ StorageClass 'local-path' no existe"
    echo "   K3s debería crear esto automáticamente"
fi

# ============================================
# 14. VERIFICAR SERVICIOS
# ============================================

log "14. Verificando servicios..."

echo ""
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get svc -n coarlumini 2>/dev/null" || \
    warning "⚠ No se pudieron obtener los servicios"
echo ""

# ============================================
# 15. VERIFICAR WORKERS
# ============================================

log "15. Verificando instancias de workers..."

echo ""
echo "Workers en el instance group:"
gcloud compute instances list --filter="name:k3s-agent-*" \
    --format="table(name,zone,status,networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)"
echo ""

WORKER_COUNT=$(gcloud compute instances list --filter="name:k3s-agent-*" \
    --format="value(name)" | wc -l)

if [ "$WORKER_COUNT" -gt "0" ]; then
    success "✓ Workers encontrados: $WORKER_COUNT"

    # Verificar primer worker
    FIRST_WORKER=$(gcloud compute instances list --filter="name:k3s-agent-*" \
        --format="value(name)" | head -n1)

    log "Verificando imágenes en worker: $FIRST_WORKER"
    gcloud compute ssh $FIRST_WORKER --zone=$ZONE \
        --command="docker images | grep coarlumini || echo 'No hay imágenes de coarlumini'" || \
        warning "⚠ No se pudo verificar el worker"
else
    warning "⚠ No se encontraron workers"
    echo "   El autoscaler puede tardar en crear instancias"
fi

# ============================================
# 16. VERIFICAR SERVICE ACCOUNT PERMISSIONS
# ============================================

log "16. Verificando permisos del service account..."

SA_EMAIL="k3s-cluster-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo ""
echo "Roles del service account $SA_EMAIL:"
gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:$SA_EMAIL" \
    --format="table(bindings.role)"
echo ""

# ============================================
# 17. DIAGNOSTICAR PODS CON PROBLEMAS
# ============================================

log "17. Diagnosticando pods con problemas..."

echo ""
echo "Pods que NO están Running:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get pods -n coarlumini --field-selector=status.phase!=Running 2>/dev/null" || \
    echo "No se pudieron obtener pods"
echo ""

echo "Eventos recientes en el namespace:"
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get events -n coarlumini --sort-by='.lastTimestamp' 2>/dev/null | tail -20" || \
    echo "No se pudieron obtener eventos"
echo ""

# ============================================
# 18. VERIFICAR CONECTIVIDAD AL API SERVER
# ============================================

log "18. Verificando conectividad al API server (puerto 6443)..."

if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$MASTER_EXTERNAL_IP/6443" 2>/dev/null; then
    success "✓ Puerto 6443 es accesible desde esta máquina"
else
    warning "⚠ No se puede conectar al puerto 6443 desde esta máquina"
    echo "   Esto es normal si el API server solo escucha internamente"
    echo "   Puedes acceder por SSH al master para usar kubectl"
fi

# ============================================
# RESUMEN
# ============================================

echo ""
echo "=========================================="
echo "  RESUMEN DEL DIAGNÓSTICO"
echo "=========================================="
echo ""
echo "✅ Checks completados"
echo ""
echo "📊 Estado del cluster:"
echo "   • Master: $K3S_SERVER_NAME"
echo "   • IP Externa: $MASTER_EXTERNAL_IP"
echo "   • IP Interna: $MASTER_INTERNAL_IP"
echo "   • Estado K3s: $K3S_STATUS"
echo "   • Nodos: $NODE_COUNT"
echo "   • Workers: $WORKER_COUNT"
echo ""
echo "=========================================="
echo ""
echo "💡 Próximos pasos sugeridos:"
echo ""
echo "1. Si hay problemas con imágenes:"
echo "   cd autoscaling-demo && ./scripts/build-and-push.sh"
echo ""
echo "2. Si hay problemas con pods:"
echo "   gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo "   sudo kubectl describe pod <pod-name> -n coarlumini"
echo "   sudo kubectl logs <pod-name> -n coarlumini"
echo ""
echo "3. Para ver logs del sistema:"
echo "   gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo "   sudo journalctl -u k3s -f"
echo ""
echo "4. Para reiniciar el deployment:"
echo "   cd autoscaling-demo"
echo "   tofu destroy -auto-approve"
echo "   ./scripts/full-deploy.sh"
echo ""
echo "=========================================="
echo ""

exit 0
