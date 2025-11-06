#!/bin/bash
set -e

# ============================================
# BUILD AND PUSH DOCKER IMAGES TO GCR
# ============================================
# Este script construye las imágenes Docker de
# Coarlumini y las sube a Google Container Registry
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
# VERIFICAR VARIABLES DE ENTORNO
# ============================================

if [ -z "$PROJECT_ID" ]; then
    error "PROJECT_ID no está definido. Exporta: export PROJECT_ID=tu-proyecto-gcp"
fi

log "Construyendo imágenes Docker para Coarlumini"
log "Proyecto GCP: $PROJECT_ID"

# ============================================
# UBICAR DIRECTORIO COARLUMINI
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COARLUMINI_DIR="$SCRIPT_DIR/../../coarlumini"

if [ ! -d "$COARLUMINI_DIR" ]; then
    error "Directorio coarlumini no encontrado en: $COARLUMINI_DIR"
fi

log "Directorio coarlumini: $COARLUMINI_DIR"

# ============================================
# VERIFICAR DOCKERFILES
# ============================================

if [ ! -f "$COARLUMINI_DIR/database/Dockerfile" ]; then
    error "Dockerfile de database no encontrado"
fi

if [ ! -f "$COARLUMINI_DIR/Dockerfile" ]; then
    error "Dockerfile de backend no encontrado"
fi

if [ ! -f "$COARLUMINI_DIR/frontend/Dockerfile" ]; then
    error "Dockerfile de frontend no encontrado"
fi

success "Todos los Dockerfiles encontrados"

# ============================================
# AUTENTICAR DOCKER CON GCR
# ============================================

log "Autenticando Docker con Google Container Registry..."
gcloud auth configure-docker gcr.io --quiet || error "Fallo autenticación con GCR"
success "Autenticación exitosa"

# ============================================
# CONSTRUIR IMAGEN DATABASE
# ============================================

log "=========================================="
log "Construyendo imagen DATABASE (MySQL)..."
log "=========================================="

cd "$COARLUMINI_DIR/database"

docker build -t gcr.io/${PROJECT_ID}/coarlumini-database:latest \
    -f Dockerfile . || error "Fallo construyendo imagen database"

success "✓ Imagen database construida: gcr.io/${PROJECT_ID}/coarlumini-database:latest"

# ============================================
# CONSTRUIR IMAGEN BACKEND
# ============================================

log "=========================================="
log "Construyendo imagen BACKEND (Laravel)..."
log "=========================================="

cd "$COARLUMINI_DIR"

docker build -t gcr.io/${PROJECT_ID}/coarlumini-backend:latest \
    -f Dockerfile . || error "Fallo construyendo imagen backend"

success "✓ Imagen backend construida: gcr.io/${PROJECT_ID}/coarlumini-backend:latest"

# ============================================
# CONSTRUIR IMAGEN FRONTEND
# ============================================

log "=========================================="
log "Construyendo imagen FRONTEND (Vue.js)..."
log "=========================================="

cd "$COARLUMINI_DIR/frontend"

docker build -t gcr.io/${PROJECT_ID}/coarlumini-frontend:latest \
    -f Dockerfile . || error "Fallo construyendo imagen frontend"

success "✓ Imagen frontend construida: gcr.io/${PROJECT_ID}/coarlumini-frontend:latest"

# ============================================
# SUBIR IMÁGENES A GCR
# ============================================

log "=========================================="
log "Subiendo imágenes a Google Container Registry..."
log "=========================================="

log "Subiendo imagen database..."
docker push gcr.io/${PROJECT_ID}/coarlumini-database:latest || error "Fallo subiendo database"
success "✓ Database subida"

log "Subiendo imagen backend..."
docker push gcr.io/${PROJECT_ID}/coarlumini-backend:latest || error "Fallo subiendo backend"
success "✓ Backend subido"

log "Subiendo imagen frontend..."
docker push gcr.io/${PROJECT_ID}/coarlumini-frontend:latest || error "Fallo subiendo frontend"
success "✓ Frontend subido"

# ============================================
# RESUMEN
# ============================================

echo ""
echo "=========================================="
success "✓ TODAS LAS IMÁGENES CONSTRUIDAS Y SUBIDAS EXITOSAMENTE"
echo "=========================================="
echo ""
echo "Imágenes disponibles en Google Container Registry:"
echo ""
echo "  📦 Database:  gcr.io/${PROJECT_ID}/coarlumini-database:latest"
echo "  📦 Backend:   gcr.io/${PROJECT_ID}/coarlumini-backend:latest"
echo "  📦 Frontend:  gcr.io/${PROJECT_ID}/coarlumini-frontend:latest"
echo ""
echo "Puedes verificar las imágenes con:"
echo "  gcloud container images list --repository=gcr.io/${PROJECT_ID}"
echo ""
echo "=========================================="

exit 0
