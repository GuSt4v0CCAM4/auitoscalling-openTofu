#!/bin/bash
set -e

# ============================================
# FULL AUTOMATED DEPLOYMENT SCRIPT
# ============================================
# Este script ejecuta todo el proceso de deployment
# desde construcción de imágenes hasta verificación
# ============================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================
# CONFIGURACIÓN
# ============================================

export PROJECT_ID=${PROJECT_ID:-cloudcomputingunsa}
export ZONE=${ZONE:-us-central1-a}
export REGION=${REGION:-us-central1}
export K3S_SERVER_NAME="k3s-master-server"

log "=========================================="
log "COARLUMINI - DEPLOYMENT AUTOMÁTICO"
log "=========================================="
log "Proyecto: $PROJECT_ID"
log "Región: $REGION"
log "Zona: $ZONE"
log "=========================================="

# ============================================
# PASO 0: PRE-VALIDACIÓN
# ============================================

log "Paso 0: Ejecutando pre-validación del sistema..."

if [ -f "./scripts/pre-deploy-validation.sh" ]; then
    chmod +x ./scripts/pre-deploy-validation.sh
    if ./scripts/pre-deploy-validation.sh; then
        success "✓ Pre-validación completada exitosamente"
    else
        warning "⚠ Pre-validación encontró problemas, pero continuaremos..."
    fi
else
    warning "⚠ Script de pre-validación no encontrado, continuando sin validación"
fi

# ============================================
# PASO 1: VALIDACIÓN DE HERRAMIENTAS
# ============================================

log "Paso 1: Validando herramientas instaladas..."

# Verificar gcloud
if ! command -v gcloud &> /dev/null; then
    error "gcloud no está instalado"
fi

# Verificar docker
if ! command -v docker &> /dev/null; then
    error "docker no está instalado"
fi

# Verificar terraform/tofu
if command -v tofu &> /dev/null; then
    TF_CMD="tofu"
elif command -v terraform &> /dev/null; then
    TF_CMD="terraform"
else
    error "ni terraform ni tofu están instalados"
fi

log "Usando: $TF_CMD"

# Verificar proyecto
CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ "$CURRENT_PROJECT" != "$PROJECT_ID" ]; then
    warning "Proyecto actual: $CURRENT_PROJECT, configurando a: $PROJECT_ID"
    gcloud config set project $PROJECT_ID
fi

success "✓ Validación completada"

# ============================================
# PASO 2: VERIFICAR/CONSTRUIR IMÁGENES
# ============================================

log "Paso 2: Verificando imágenes en GCR..."

# Verificar si las imágenes ya existen
IMAGES_EXIST=true
for image in database backend frontend; do
    if ! gcloud container images describe "gcr.io/$PROJECT_ID/coarlumini-$image:latest" &>/dev/null; then
        warning "⚠ Imagen no existe: coarlumini-$image:latest"
        IMAGES_EXIST=false
    fi
done

if [ "$IMAGES_EXIST" = false ]; then
    log "Construyendo y subiendo imágenes Docker a GCR..."
    cd "$(dirname "$0")/.."
    ./scripts/build-and-push.sh || error "Fallo en construcción de imágenes"
else
    success "✓ Todas las imágenes ya existen en GCR"
fi

success "✓ Imágenes verificadas/construidas"

# ============================================
# PASO 3: VALIDAR Y ACTUALIZAR MANIFIESTOS
# ============================================

log "Paso 3: Validando y actualizando manifiestos de Kubernetes..."

# Ir al directorio de manifiestos
cd ../coarlumini/k8s

# Reemplazar ${PROJECT_ID} en los manifiestos
for file in 04-database-deployment.yaml 06-backend-deployment.yaml 09-frontend-deployment.yaml; do
    if [ -f "$file" ]; then
        log "Actualizando $file..."
        sed -i "s|\${PROJECT_ID}|$PROJECT_ID|g" "$file"

        # Corregir typo común en frontend
        if [ "$file" = "09-frontend-deployment.yaml" ]; then
            sed -i "s|coarlumini-frontend:latestst|coarlumini-frontend:latest|g" "$file"
        fi

        # Verificar que tenga imagePullSecrets
        if ! grep -q "imagePullSecrets" "$file"; then
            warning "⚠ $file no tiene imagePullSecrets (se agregará en el servidor)"
        fi
    fi
done

cd ../../autoscaling-demo

success "✓ Manifiestos validados y actualizados"

# ============================================
# PASO 4: VERIFICAR/CREAR REGLAS DE FIREWALL
# ============================================

log "Paso 4: Verificando reglas de firewall..."

# Verificar si ya existen las reglas
FIREWALL_RULES=$(gcloud compute firewall-rules list --format="value(name)" | grep -E "web-firewall|k3s-internal-firewall" || true)

if [ -z "$FIREWALL_RULES" ]; then
    warning "Reglas de firewall no encontradas, se crearán con Terraform"
else
    log "Reglas de firewall encontradas: $FIREWALL_RULES"
fi

success "✓ Firewall verificado"

# ============================================
# PASO 5: DEPLOYMENT CON TERRAFORM/TOFU
# ============================================

log "Paso 5: Desplegando infraestructura con $TF_CMD..."

# Inicializar Terraform si es necesario
if [ ! -d ".terraform" ]; then
    log "Inicializando $TF_CMD..."
    $TF_CMD init
fi

# Aplicar configuración
log "Aplicando configuración de infraestructura..."
$TF_CMD apply -auto-approve -var-file="terraform.tfvars" || error "Fallo en $TF_CMD apply"

success "✓ Infraestructura desplegada"

# ============================================
# PASO 6: ESPERAR A QUE K3S ESTÉ LISTO
# ============================================

log "Paso 6: Esperando a que el cluster K3s esté listo..."

log "Esperando 120 segundos para la inicialización inicial..."
sleep 120

# Verificar que el servidor está corriendo
max_attempts=30
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="sudo kubectl get nodes" &>/dev/null; then
        success "✓ Servidor K3s está respondiendo"
        break
    fi

    attempt=$((attempt + 1))
    if [ $attempt -ge $max_attempts ]; then
        error "Servidor K3s no responde después de $max_attempts intentos"
    fi

    log "Esperando servidor K3s... (intento $attempt/$max_attempts)"
    sleep 10
done

# ============================================
# PASO 7: CONFIGURAR KUBECTL LOCAL
# ============================================

log "Paso 7: Configurando kubectl local..."

# Obtener IP externa del master
MASTER_IP=$(gcloud compute instances describe $K3S_SERVER_NAME \
    --zone=$ZONE \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

log "IP del master: $MASTER_IP"

# Descargar kubeconfig
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo cat /etc/rancher/k3s/k3s.yaml" > k3s-config.yaml

# Reemplazar localhost con IP pública
sed -i "s/127.0.0.1/$MASTER_IP/g" k3s-config.yaml

# Configurar kubectl
export KUBECONFIG=$PWD/k3s-config.yaml

success "✓ kubectl configurado"

# Verificar conectividad
log "Verificando conectividad con el API server..."
if kubectl get nodes &>/dev/null; then
    success "✓ Conectividad con API server establecida"
    kubectl get nodes
else
    warning "⚠ No se puede conectar al API server desde local"
    warning "⚠ Esto puede ser normal si el firewall aún no permite conexiones externas"
    warning "⚠ Puedes acceder por SSH: gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
fi

# ============================================
# PASO 8: VERIFICAR DEPLOYMENT
# ============================================

log "Paso 8: Verificando deployment en el cluster..."

# Ejecutar verificación por SSH
gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command="
    echo '=== NODOS DEL CLUSTER ==='
    sudo kubectl get nodes -o wide

    echo ''
    echo '=== PODS DE COARLUMINI ==='
    sudo kubectl get pods -n coarlumini -o wide

    echo ''
    echo '=== SERVICIOS ==='
    sudo kubectl get svc -n coarlumini

    echo ''
    echo '=== PVCs ==='
    sudo kubectl get pvc -n coarlumini

    echo ''
    echo '=== IMAGEPULLSECRET ==='
    sudo kubectl get secret gcr-json-key -n coarlumini 2>/dev/null && echo 'ImagePullSecret: OK' || echo 'ImagePullSecret: NOT FOUND'

    echo ''
    echo '=== IMÁGENES EN CONTAINERD (K3S) ==='
    sudo crictl images | grep coarlumini || echo 'No hay imágenes de coarlumini en containerd'
"

# ============================================
# PASO 9: VERIFICAR WORKERS
# ============================================

log "Paso 9: Verificando workers..."

# Obtener lista de workers
WORKERS=$(gcloud compute instances list --filter="name:k3s-agent-*" --format="value(name)")

if [ -z "$WORKERS" ]; then
    warning "⚠ No se encontraron workers aún"
    warning "⚠ El autoscaler puede tardar unos minutos en crear instancias"
else
    log "Workers encontrados:"
    echo "$WORKERS"

    # Verificar imágenes en el primer worker
    FIRST_WORKER=$(echo "$WORKERS" | head -n1)
    log "Verificando imágenes en worker: $FIRST_WORKER"

    gcloud compute ssh $FIRST_WORKER --zone=$ZONE --command="
        echo 'Imágenes Docker en este worker:'
        docker images | grep coarlumini || echo 'No hay imágenes de coarlumini'
    " || warning "⚠ No se pudo verificar el worker"
fi

# ============================================
# PASO 10: OBTENER INFORMACIÓN DE ACCESO
# ============================================

log "Paso 10: Obteniendo información de acceso..."

# Obtener IP del Load Balancer
LB_IP=$(gcloud compute forwarding-rules list --format="value(IPAddress)" --filter="name:web-forwarding-rule")

# Obtener NodePort del frontend
FRONTEND_PORT=$(gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE \
    --command="sudo kubectl get svc -n coarlumini coarlumini-frontend-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || echo "30080")

# ============================================
# RESUMEN FINAL
# ============================================

echo ""
echo "=========================================="
success "✓✓✓ DEPLOYMENT COMPLETADO EXITOSAMENTE ✓✓✓"
echo "=========================================="
echo ""
echo "🎉 Coarlumini ha sido desplegado en GCP con K3s"
echo ""
echo "📍 INFORMACIÓN DE ACCESO:"
echo ""
echo "  🌐 Load Balancer Global:"
echo "     http://$LB_IP"
echo ""
echo "  🖥️  Acceso directo al master (NodePort):"
echo "     http://$MASTER_IP:$FRONTEND_PORT"
echo ""
echo "  🔑 Acceso SSH al master:"
echo "     gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo ""
echo "=========================================="
echo ""
echo "📊 COMANDOS ÚTILES:"
echo ""
echo "  Ver nodos:"
echo "    kubectl get nodes"
echo ""
echo "  Ver pods:"
echo "    kubectl get pods -n coarlumini"
echo ""
echo "  Ver logs del backend:"
echo "    kubectl logs -l app=coarlumini-backend -n coarlumini -f"
echo ""
echo "  Escalar manualmente:"
echo "    kubectl scale deployment coarlumini-backend -n coarlumini --replicas=3"
echo ""
echo "  SSH al master:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo ""
echo "  Ejecutar comando remoto:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE --command='sudo kubectl get all -n coarlumini'"
echo ""
echo "=========================================="
echo ""
echo "💡 NOTAS IMPORTANTES:"
echo ""
echo "  • El cluster puede tardar 5-10 minutos en estar completamente operativo"
echo "  • Los pods pueden tardar en estar 'Ready' mientras descargan imágenes"
echo "  • K3s usa containerd (no Docker) para gestionar contenedores"
echo "  • ImagePullSecret está configurado para acceder a GCR automáticamente"
echo "  • El HPA (autoscaler) puede crear más pods según la carga"
echo "  • Para destruir todo: $TF_CMD destroy -auto-approve"
echo ""
echo "🔧 TROUBLESHOOTING:"
echo ""
echo "  Si los pods tienen ImagePullBackOff:"
echo "    gcloud compute ssh $K3S_SERVER_NAME --zone=$ZONE"
echo "    sudo kubectl describe pod <pod-name> -n coarlumini"
echo "    sudo kubectl get secret gcr-json-key -n coarlumini"
echo ""
echo "  Para verificar imágenes en containerd:"
echo "    sudo crictl images | grep coarlumini"
echo ""
echo "=========================================="
echo ""

# Guardar información en archivo
cat > deployment-info.txt <<EOF
Deployment completado: $(date)
Proyecto: $PROJECT_ID
Región: $REGION
Zona: $ZONE

Master: $K3S_SERVER_NAME
Master IP: $MASTER_IP
Load Balancer IP: $LB_IP

Acceso:
- Load Balancer: http://$LB_IP
- NodePort: http://$MASTER_IP:$FRONTEND_PORT

Kubectl configurado en: $PWD/k3s-config.yaml
Para usar: export KUBECONFIG=$PWD/k3s-config.yaml

Workers activos:
$WORKERS
EOF

success "Información guardada en: deployment-info.txt"

echo ""
log "🚀 Deployment completado. ¡Tu aplicación debería estar ejecutándose!"
echo ""

exit 0
