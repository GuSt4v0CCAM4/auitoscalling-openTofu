#!/bin/bash
set -e

# ============================================
# PRE-DEPLOYMENT VALIDATION SCRIPT
# ============================================
# Este script valida que todo esté listo antes
# de hacer el deployment completo
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

ERRORS=0
WARNINGS=0

echo ""
echo "=========================================="
log "  VALIDACIÓN PRE-DEPLOYMENT"
echo "=========================================="
echo ""

export PROJECT_ID=${PROJECT_ID:-cloudcomputingunsa}

# ============================================
# 1. VALIDAR MANIFIESTOS DE KUBERNETES
# ============================================

log "1. Validando manifiestos de Kubernetes..."

MANIFEST_DIR="../coarlumini/k8s"

if [ ! -d "$MANIFEST_DIR" ]; then
    error "❌ Directorio de manifiestos no encontrado: $MANIFEST_DIR"
    ERRORS=$((ERRORS + 1))
else
    success "✓ Directorio de manifiestos encontrado"

    # Verificar archivos críticos
    CRITICAL_FILES=(
        "00-namespace.yaml"
        "01-configmap.yaml"
        "02-secrets.yaml"
        "03-database-pvc.yaml"
        "04-database-deployment.yaml"
        "05-database-service.yaml"
        "06-backend-deployment.yaml"
        "08-backend-service.yaml"
        "09-frontend-deployment.yaml"
        "11-nginx-config.yaml"
        "12-frontend-service.yaml"
    )

    for file in "${CRITICAL_FILES[@]}"; do
        if [ ! -f "$MANIFEST_DIR/$file" ]; then
            error "❌ Archivo faltante: $file"
            ERRORS=$((ERRORS + 1))
        else
            success "✓ $file existe"
        fi
    done
fi

# ============================================
# 2. VALIDAR IMAGEPULLSECRETS EN DEPLOYMENTS
# ============================================

log ""
log "2. Validando imagePullSecrets en deployments..."

for deployment in "04-database-deployment.yaml" "06-backend-deployment.yaml" "09-frontend-deployment.yaml"; do
    if [ -f "$MANIFEST_DIR/$deployment" ]; then
        if grep -q "imagePullSecrets" "$MANIFEST_DIR/$deployment"; then
            success "✓ $deployment tiene imagePullSecrets"
        else
            warning "⚠ $deployment NO tiene imagePullSecrets"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
done

# ============================================
# 3. VALIDAR TAGS DE IMÁGENES
# ============================================

log ""
log "3. Validando tags de imágenes..."

# Verificar typo común en frontend
if [ -f "$MANIFEST_DIR/09-frontend-deployment.yaml" ]; then
    if grep -q "latestst" "$MANIFEST_DIR/09-frontend-deployment.yaml"; then
        error "❌ Tag incorrecto 'latestst' encontrado en frontend deployment"
        ERRORS=$((ERRORS + 1))
    else
        success "✓ Tag de imagen frontend correcto"
    fi
fi

# Verificar que todas las imágenes usan :latest
for deployment in "04-database-deployment.yaml" "06-backend-deployment.yaml" "09-frontend-deployment.yaml"; do
    if [ -f "$MANIFEST_DIR/$deployment" ]; then
        if grep -q "image:.*:latest" "$MANIFEST_DIR/$deployment"; then
            success "✓ $deployment usa tag :latest"
        else
            warning "⚠ $deployment podría no tener tag :latest"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
done

# ============================================
# 4. VALIDAR IMÁGENES EN GCR
# ============================================

log ""
log "4. Validando imágenes en Google Container Registry..."

if command -v gcloud &> /dev/null; then
    for image in database backend frontend; do
        if gcloud container images describe "gcr.io/$PROJECT_ID/coarlumini-$image:latest" &>/dev/null; then
            success "✓ Imagen existe en GCR: coarlumini-$image:latest"
        else
            error "❌ Imagen NO existe en GCR: coarlumini-$image:latest"
            ERRORS=$((ERRORS + 1))
        fi
    done
else
    warning "⚠ gcloud no está instalado, no se pueden verificar imágenes en GCR"
    WARNINGS=$((WARNINGS + 1))
fi

# ============================================
# 5. VALIDAR DOCKERFILES
# ============================================

log ""
log "5. Validando Dockerfiles..."

DOCKERFILE_PATHS=(
    "../coarlumini/Dockerfile:backend"
    "../coarlumini/frontend/Dockerfile:frontend"
    "../coarlumini/database/Dockerfile:database"
)

for path_info in "${DOCKERFILE_PATHS[@]}"; do
    IFS=':' read -r path name <<< "$path_info"
    if [ -f "$path" ]; then
        success "✓ Dockerfile de $name existe"
    else
        error "❌ Dockerfile de $name no encontrado: $path"
        ERRORS=$((ERRORS + 1))
    fi
done

# ============================================
# 6. VALIDAR SERVICE ACCOUNT
# ============================================

log ""
log "6. Validando Service Account..."

SA_EMAIL="k3s-cluster-sa@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    success "✓ Service Account existe: $SA_EMAIL"

    # Verificar permisos
    log "Verificando permisos del Service Account..."

    ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
        --flatten="bindings[].members" \
        --filter="bindings.members:serviceAccount:$SA_EMAIL" \
        --format="value(bindings.role)" 2>/dev/null || echo "")

    if echo "$ROLES" | grep -q "storage.objectViewer"; then
        success "✓ Service Account tiene rol storage.objectViewer"
    else
        warning "⚠ Service Account podría no tener rol storage.objectViewer"
        WARNINGS=$((WARNINGS + 1))
    fi

else
    error "❌ Service Account no existe: $SA_EMAIL"
    ERRORS=$((ERRORS + 1))
fi

# ============================================
# 7. VALIDAR CONFIGURACIÓN DE TERRAFORM/TOFU
# ============================================

log ""
log "7. Validando configuración de Terraform/Tofu..."

if [ -f "../terraform.tfvars" ]; then
    success "✓ terraform.tfvars existe"

    # Verificar PROJECT_ID
    if grep -q "project_id.*=.*\"$PROJECT_ID\"" "../terraform.tfvars"; then
        success "✓ PROJECT_ID configurado correctamente en terraform.tfvars"
    else
        warning "⚠ PROJECT_ID en terraform.tfvars podría no coincidir"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    error "❌ terraform.tfvars no encontrado"
    ERRORS=$((ERRORS + 1))
fi

if [ -f "../main.tf" ]; then
    success "✓ main.tf existe"
else
    error "❌ main.tf no encontrado"
    ERRORS=$((ERRORS + 1))
fi

# ============================================
# 8. VALIDAR SCRIPTS DE INICIALIZACIÓN
# ============================================

log ""
log "8. Validando scripts de inicialización..."

INIT_SCRIPTS=(
    "k3s-server-init.sh"
    "k3s-agent-init.sh"
    "build-and-push.sh"
    "deploy-to-k3s.sh"
)

for script in "${INIT_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        if [ -x "$script" ]; then
            success "✓ $script existe y es ejecutable"
        else
            warning "⚠ $script existe pero no es ejecutable"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        error "❌ Script no encontrado: $script"
        ERRORS=$((ERRORS + 1))
    fi
done

# ============================================
# 9. VALIDAR QUE K3S-SERVER-INIT USA CRICTL
# ============================================

log ""
log "9. Validando que scripts usan crictl (containerd) en lugar de docker..."

if [ -f "k3s-server-init.sh" ]; then
    if grep -q "crictl pull" "k3s-server-init.sh"; then
        success "✓ k3s-server-init.sh usa crictl"
    else
        warning "⚠ k3s-server-init.sh podría estar usando docker en lugar de crictl"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

if [ -f "k3s-agent-init.sh" ]; then
    if grep -q "crictl pull" "k3s-agent-init.sh"; then
        success "✓ k3s-agent-init.sh usa crictl"
    else
        warning "⚠ k3s-agent-init.sh podría estar usando docker en lugar de crictl"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ============================================
# 10. VALIDAR NGINX-CONFIG
# ============================================

log ""
log "10. Validando nginx-config..."

if [ -f "$MANIFEST_DIR/11-nginx-config.yaml" ]; then
    success "✓ nginx-config.yaml existe"

    # Verificar que es un ConfigMap
    if grep -q "kind: ConfigMap" "$MANIFEST_DIR/11-nginx-config.yaml"; then
        success "✓ nginx-config.yaml es un ConfigMap"
    else
        error "❌ nginx-config.yaml no es un ConfigMap válido"
        ERRORS=$((ERRORS + 1))
    fi
else
    error "❌ nginx-config.yaml no encontrado"
    ERRORS=$((ERRORS + 1))
fi

# ============================================
# RESUMEN
# ============================================

echo ""
echo "=========================================="
echo "  RESUMEN DE VALIDACIÓN"
echo "=========================================="
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    success "✓✓✓ TODAS LAS VALIDACIONES PASARON ✓✓✓"
    echo ""
    echo "🎉 El sistema está listo para deployment"
    echo ""
    echo "Próximo paso:"
    echo "  ./scripts/full-deploy.sh"
    echo ""
    exit 0
elif [ $ERRORS -eq 0 ]; then
    warning "⚠ VALIDACIÓN COMPLETADA CON ADVERTENCIAS"
    echo ""
    echo "Advertencias encontradas: $WARNINGS"
    echo ""
    echo "El deployment puede continuar, pero revisa las advertencias."
    echo ""
    echo "Para continuar:"
    echo "  ./scripts/full-deploy.sh"
    echo ""
    exit 0
else
    error "❌ VALIDACIÓN FALLÓ"
    echo ""
    echo "Errores encontrados: $ERRORS"
    echo "Advertencias: $WARNINGS"
    echo ""
    echo "❌ NO se recomienda continuar con el deployment"
    echo ""
    echo "Corrige los errores listados arriba antes de continuar."
    echo ""
    exit 1
fi
