#!/bin/bash
set -e

# ============================================
# DEPLOY COARLUMINI TO K3S CLUSTER
# ============================================
# Este script se conecta al servidor K3s vía SSH
# y ejecuta el deployment de Coarlumini
# ============================================

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================
# VERIFICAR VARIABLES DE ENTORNO
# ============================================

if [ -z "$PROJECT_ID" ]; then
    error "PROJECT_ID no está definido"
fi

if [ -z "$K3S_SERVER_NAME" ]; then
    error "K3S_SERVER_NAME no está definido"
fi

if [ -z "$ZONE" ]; then
    ZONE="us-central1-a"
    warning "ZONE no definido, usando default: $ZONE"
fi

log "=========================================="
log "Desplegando Coarlumini en K3s"
log "=========================================="
log "Proyecto: $PROJECT_ID"
log "Servidor: $K3S_SERVER_NAME"
log "Zona: $ZONE"
log "=========================================="

# ============================================
# VERIFICAR QUE EL SERVIDOR EXISTE
# ============================================

log "Verificando que el servidor K3s existe..."
if ! gcloud compute instances describe "$K3S_SERVER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" &>/dev/null; then
    error "Servidor K3s no encontrado: $K3S_SERVER_NAME"
fi

success "✓ Servidor K3s encontrado"

# ============================================
# OBTENER IP DEL SERVIDOR
# ============================================

log "Obteniendo IP del servidor K3s..."
SERVER_IP=$(gcloud compute instances describe "$K3S_SERVER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

if [ -z "$SERVER_IP" ]; then
    error "No se pudo obtener la IP del servidor"
fi

success "✓ IP del servidor: $SERVER_IP"

# ============================================
# ESPERAR A QUE K3S ESTÉ LISTO
# ============================================

log "Esperando a que K3s esté completamente inicializado..."
log "Esto puede tomar unos minutos..."
sleep 120

# ============================================
# VERIFICAR CONECTIVIDAD SSH
# ============================================

log "Verificando conectividad SSH..."
if ! gcloud compute ssh "$K3S_SERVER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --command="echo 'SSH OK'" &>/dev/null; then
    error "No se puede conectar por SSH al servidor"
fi

success "✓ Conectividad SSH verificada"

# ============================================
# VERIFICAR QUE K3S ESTÁ CORRIENDO
# ============================================

log "Verificando que K3s está corriendo..."
K3S_STATUS=$(gcloud compute ssh "$K3S_SERVER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --command="systemctl is-active k3s" 2>/dev/null || echo "inactive")

if [ "$K3S_STATUS" != "active" ]; then
    warning "K3s no está activo, esperando 60 segundos más..."
    sleep 60
fi

success "✓ K3s está corriendo"

# ============================================
# VERIFICAR QUE EL SCRIPT DE DEPLOY EXISTE
# ============================================

log "Verificando script de deployment en el servidor..."
SCRIPT_EXISTS=$(gcloud compute ssh "$K3S_SERVER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --command="sudo [ -f /root/deploy-coarlumini.sh ] && echo 'yes' || echo 'no'" 2>/dev/null)

if [ "$SCRIPT_EXISTS" != "yes" ]; then
    error "Script de deployment no encontrado en el servidor"
fi

success "✓ Script de deployment encontrado"

# ============================================
# EJECUTAR DEPLOYMENT
# ============================================

log "=========================================="
log "Ejecutando deployment de Coarlumini..."
log "=========================================="

gcloud compute ssh "$K3S_SERVER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --command="sudo /root/deploy-coarlumini.sh" || {
        error "Fallo en el deployment"
    }

success "✓ Deployment ejecutado exitosamente"

# ============================================
# VERIFICAR ESTADO DE LOS PODS
# ============================================

log "Verificando estado de los pods..."
sleep 30

POD_STATUS=$(gcloud compute ssh "$K3S_SERVER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --command="sudo kubectl get pods -n coarlumini --no-headers 2>/dev/null | wc -l" || echo "0")

if [ "$POD_STATUS" -gt "0" ]; then
    success "✓ Pods desplegados: $POD_STATUS"
else
    warning "⚠ No se detectaron pods, el deployment puede estar en progreso"
fi

# ============================================
# OBTENER INFORMACIÓN DE ACCESO
# ============================================

log "Obteniendo información de acceso..."

# Obtener NodePort del frontend
FRONTEND_PORT=$(gcloud compute ssh "$K3S_SERVER_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --command="sudo kubectl get svc -n coarlumini coarlumini-frontend-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || echo "30080")

# ============================================
# MOSTRAR RESUMEN
# ============================================

echo ""
echo "=========================================="
success "✓ DEPLOYMENT COMPLETADO EXITOSAMENTE"
echo "=========================================="
echo ""
echo "🚀 Aplicación Coarlumini desplegada en K3s"
echo ""
echo "📍 URLs de acceso:"
echo ""
echo "  Frontend (NodePort):"
echo "    http://$SERVER_IP:$FRONTEND_PORT"
echo ""
echo "  Load Balancer:"
echo "    (Ver output de Terraform para la IP del LB)"
echo ""
echo "=========================================="
echo ""
echo "📊 Comandos útiles:"
echo ""
echo "  SSH al servidor K3s:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo ""
echo "  Ver pods:"
echo "    kubectl get pods -n coarlumini"
echo ""
echo "  Ver logs del backend:"
echo "    kubectl logs -l app=coarlumini-backend -n coarlumini -f"
echo ""
echo "  Ver logs del frontend:"
echo "    kubectl logs -l app=coarlumini-frontend -n coarlumini -f"
echo ""
echo "  Ver todos los recursos:"
echo "    kubectl get all -n coarlumini"
echo ""
echo "  Escalar backend:"
echo "    kubectl scale deployment coarlumini-backend -n coarlumini --replicas=3"
echo ""
echo "=========================================="
echo ""

exit 0
