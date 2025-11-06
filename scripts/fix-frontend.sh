#!/bin/bash
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

export ZONE=us-central1-a
export K3S_SERVER_NAME="k3s-master-server"

log "Corrigiendo problemas del frontend..."

gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command='
set -e

# Encontrar directorio de manifiestos
if sudo test -d /root/k8s-manifests; then
    MANIFEST_DIR=/root/k8s-manifests
else
    MANIFEST_DIR=$(sudo find /home -name "k8s-manifests" -type d 2>/dev/null | head -n1)
fi

echo "Directorio de manifiestos: $MANIFEST_DIR"

# 1. Aplicar nginx-config
echo ""
echo "=== Aplicando nginx-config ==="
sudo kubectl apply -f $MANIFEST_DIR/11-nginx-config.yaml

# 2. Corregir el tag de la imagen del frontend
echo ""
echo "=== Corrigiendo tag de imagen del frontend ==="
sudo sed -i "s/coarlumini-frontend:latestst/coarlumini-frontend:latest/g" $MANIFEST_DIR/09-frontend-deployment.yaml

# Verificar el cambio
echo "Verificando cambio:"
sudo grep "image:.*frontend" $MANIFEST_DIR/09-frontend-deployment.yaml

# 3. Reaplicar deployment del frontend
echo ""
echo "=== Reaplicando deployment del frontend ==="
sudo kubectl delete pod -l app=coarlumini-frontend -n coarlumini --force --grace-period=0
sudo kubectl apply -f $MANIFEST_DIR/09-frontend-deployment.yaml

echo ""
echo "✓ Correcciones aplicadas"
'

log "Esperando 30 segundos para que los pods se inicialicen..."
sleep 30

echo ""
echo "=========================================="
echo "ESTADO ACTUALIZADO DE LOS PODS:"
echo "=========================================="
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get pods -n coarlumini -o wide"

echo ""
success "✓ Correcciones completadas"
echo ""
echo "Si el frontend aún tiene problemas, verifica con:"
echo "  gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo "  sudo kubectl describe pod -l app=coarlumini-frontend -n coarlumini"

exit 0
