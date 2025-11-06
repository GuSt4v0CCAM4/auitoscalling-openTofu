#!/bin/bash
set -e

# ============================================
# SCRIPT DE VALIDACIÓN PRE-DEPLOYMENT
# ============================================
# Este script verifica que todo esté configurado
# correctamente antes de ejecutar terraform apply
# ============================================

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

ERRORS=0
WARNINGS=0

echo "=========================================="
echo "VALIDACIÓN PRE-DEPLOYMENT"
echo "=========================================="
echo ""

# ============================================
# 1. VERIFICAR HERRAMIENTAS INSTALADAS
# ============================================

log "1. Verificando herramientas instaladas..."

if command -v gcloud &> /dev/null; then
    success "✓ gcloud CLI instalado: $(gcloud version --format='value(core.version)' 2>/dev/null)"
else
    error "✗ gcloud CLI no está instalado"
    ERRORS=$((ERRORS + 1))
fi

if command -v docker &> /dev/null; then
    success "✓ Docker instalado: $(docker --version | awk '{print $3}' | tr -d ',')"
else
    error "✗ Docker no está instalado"
    ERRORS=$((ERRORS + 1))
fi

if command -v terraform &> /dev/null; then
    success "✓ Terraform instalado: $(terraform version -json | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1 | awk '{print $2}')"
elif command -v tofu &> /dev/null; then
    success "✓ OpenTofu instalado: $(tofu version | head -1 | awk '{print $2}')"
else
    error "✗ Terraform/OpenTofu no está instalado"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# ============================================
# 2. VERIFICAR AUTENTICACIÓN DE GCLOUD
# ============================================

log "2. Verificando autenticación de gcloud..."

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -n "$ACTIVE_ACCOUNT" ]; then
    success "✓ Autenticado como: $ACTIVE_ACCOUNT"
else
    error "✗ No hay cuenta de gcloud autenticada"
    echo "  Ejecuta: gcloud auth login"
    ERRORS=$((ERRORS + 1))
fi

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -n "$PROJECT_ID" ]; then
    success "✓ Proyecto configurado: $PROJECT_ID"
else
    warning "⚠ No hay proyecto configurado en gcloud"
    echo "  Ejecuta: gcloud config set project TU-PROJECT-ID"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# ============================================
# 3. VERIFICAR DOCKER AUTHENTICATION
# ============================================

log "3. Verificando autenticación de Docker con GCR..."

if grep -q "gcr.io" ~/.docker/config.json 2>/dev/null; then
    success "✓ Docker configurado para GCR"
else
    warning "⚠ Docker no está autenticado con GCR"
    echo "  Ejecuta: gcloud auth configure-docker gcr.io"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# ============================================
# 4. VERIFICAR ESTRUCTURA DE ARCHIVOS
# ============================================

log "4. Verificando estructura de archivos del proyecto..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COARLUMINI_DIR="$(dirname "$PROJECT_ROOT")/coarlumini"

# Archivos de Terraform
REQUIRED_TF_FILES=(
    "$PROJECT_ROOT/main.tf"
    "$PROJECT_ROOT/variables.tf"
    "$PROJECT_ROOT/outputs.tf"
)

for file in "${REQUIRED_TF_FILES[@]}"; do
    if [ -f "$file" ]; then
        success "✓ $(basename $file) encontrado"
    else
        error "✗ $(basename $file) no encontrado en: $file"
        ERRORS=$((ERRORS + 1))
    fi
done

# Scripts
REQUIRED_SCRIPTS=(
    "$SCRIPT_DIR/build-and-push.sh"
    "$SCRIPT_DIR/deploy-to-k3s.sh"
    "$SCRIPT_DIR/k3s-server-init.sh"
    "$SCRIPT_DIR/k3s-agent-init.sh"
)

for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        if [ -x "$script" ]; then
            success "✓ $(basename $script) encontrado y ejecutable"
        else
            warning "⚠ $(basename $script) encontrado pero no es ejecutable"
            echo "  Ejecuta: chmod +x $script"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        error "✗ $(basename $script) no encontrado en: $script"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""

# ============================================
# 5. VERIFICAR MANIFIESTOS DE KUBERNETES
# ============================================

log "5. Verificando manifiestos de Kubernetes..."

K8S_DIR="$COARLUMINI_DIR/k8s"

if [ ! -d "$K8S_DIR" ]; then
    error "✗ Directorio de manifiestos K8s no encontrado: $K8S_DIR"
    ERRORS=$((ERRORS + 1))
else
    MANIFEST_COUNT=$(ls -1 "$K8S_DIR"/*.yaml 2>/dev/null | wc -l)
    if [ "$MANIFEST_COUNT" -gt 0 ]; then
        success "✓ Encontrados $MANIFEST_COUNT manifiestos YAML"

        # Verificar que tengan storageClassName: local-path
        WRONG_STORAGE=$(grep -l "storageClassName: standard-rwo" "$K8S_DIR"/*.yaml 2>/dev/null || echo "")
        if [ -n "$WRONG_STORAGE" ]; then
            error "✗ Algunos PVCs tienen storageClassName incorrecto (standard-rwo en lugar de local-path):"
            echo "$WRONG_STORAGE" | while read -r file; do
                echo "    - $(basename $file)"
            done
            ERRORS=$((ERRORS + 1))
        else
            success "✓ StorageClass configurado correctamente (local-path)"
        fi
    else
        error "✗ No se encontraron manifiestos YAML en $K8S_DIR"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo ""

# ============================================
# 6. VERIFICAR DOCKERFILES
# ============================================

log "6. Verificando Dockerfiles..."

REQUIRED_DOCKERFILES=(
    "$COARLUMINI_DIR/Dockerfile"
    "$COARLUMINI_DIR/database/Dockerfile"
    "$COARLUMINI_DIR/frontend/Dockerfile"
)

for dockerfile in "${REQUIRED_DOCKERFILES[@]}"; do
    if [ -f "$dockerfile" ]; then
        success "✓ $(dirname $dockerfile | xargs basename)/Dockerfile encontrado"
    else
        error "✗ Dockerfile no encontrado en: $dockerfile"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""

# ============================================
# 7. VERIFICAR VARIABLES DE TERRAFORM
# ============================================

log "7. Verificando configuración de Terraform..."

if [ -f "$PROJECT_ROOT/terraform.tfvars" ]; then
    success "✓ terraform.tfvars encontrado"

    # Verificar que project_id esté definido
    if grep -q "^project_id" "$PROJECT_ROOT/terraform.tfvars"; then
        PROJECT_ID_TF=$(grep "^project_id" "$PROJECT_ROOT/terraform.tfvars" | cut -d'"' -f2)
        success "✓ project_id definido: $PROJECT_ID_TF"

        # Verificar que coincida con gcloud
        if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "$PROJECT_ID_TF" ]; then
            warning "⚠ project_id en terraform.tfvars ($PROJECT_ID_TF) difiere de gcloud config ($PROJECT_ID)"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        error "✗ project_id no está definido en terraform.tfvars"
        ERRORS=$((ERRORS + 1))
    fi
else
    error "✗ terraform.tfvars no encontrado"
    echo "  Copia terraform.tfvars.example a terraform.tfvars y configúralo"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# ============================================
# 8. VERIFICAR APIS DE GCP HABILITADAS
# ============================================

log "8. Verificando APIs de GCP habilitadas..."

if [ -n "$PROJECT_ID" ]; then
    REQUIRED_APIS=(
        "compute.googleapis.com"
        "storage-api.googleapis.com"
        "containerregistry.googleapis.com"
    )

    for api in "${REQUIRED_APIS[@]}"; do
        if gcloud services list --enabled --project="$PROJECT_ID" --filter="name:$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
            success "✓ API habilitada: $api"
        else
            warning "⚠ API no habilitada: $api"
            echo "  Ejecuta: gcloud services enable $api --project=$PROJECT_ID"
            WARNINGS=$((WARNINGS + 1))
        fi
    done
else
    warning "⚠ No se puede verificar APIs sin project_id configurado"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# ============================================
# 9. VERIFICAR IMÁGENES EN GCR (OPCIONAL)
# ============================================

log "9. Verificando imágenes en GCR (opcional)..."

if [ -n "$PROJECT_ID" ]; then
    IMAGE_COUNT=$(gcloud container images list --repository="gcr.io/$PROJECT_ID" 2>/dev/null | grep -c "coarlumini" || echo "0")

    if [ "$IMAGE_COUNT" -eq 3 ]; then
        success "✓ Las 3 imágenes de Coarlumini ya están en GCR"
    elif [ "$IMAGE_COUNT" -gt 0 ]; then
        warning "⚠ Solo $IMAGE_COUNT imágenes de Coarlumini en GCR (se esperan 3)"
        echo "  Las imágenes se construirán automáticamente durante terraform apply"
        WARNINGS=$((WARNINGS + 1))
    else
        warning "⚠ No hay imágenes de Coarlumini en GCR"
        echo "  Las imágenes se construirán automáticamente durante terraform apply"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    warning "⚠ No se puede verificar imágenes sin project_id configurado"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# ============================================
# RESUMEN
# ============================================

echo "=========================================="
echo "RESUMEN DE VALIDACIÓN"
echo "=========================================="
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    success "✓ TODAS LAS VALIDACIONES PASARON"
    echo ""
    echo "Todo está listo para el deployment."
    echo ""
    echo "Próximos pasos:"
    echo "  1. cd $(basename $PROJECT_ROOT)"
    echo "  2. terraform init"
    echo "  3. terraform plan -var-file=terraform.tfvars"
    echo "  4. terraform apply -var-file=terraform.tfvars"
    echo ""
    exit 0
elif [ $ERRORS -eq 0 ]; then
    warning "⚠ VALIDACIÓN COMPLETADA CON ADVERTENCIAS"
    echo ""
    echo "Advertencias encontradas: $WARNINGS"
    echo "Puedes continuar pero revisa las advertencias arriba."
    echo ""
    exit 0
else
    error "✗ VALIDACIÓN FALLIDA"
    echo ""
    echo "Errores encontrados: $ERRORS"
    echo "Advertencias encontradas: $WARNINGS"
    echo ""
    echo "Corrige los errores antes de continuar."
    echo ""
    exit 1
fi
