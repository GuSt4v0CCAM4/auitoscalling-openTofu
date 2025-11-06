# ============================================
# GOOGLE CLOUD PROJECT CONFIGURATION
# ============================================

# ID de tu proyecto de Google Cloud Platform
# Obtenerlo con: gcloud config get-value project
project_id = "cloudcomputingunsa"

# Región donde se desplegará la infraestructura
region = "us-central1"

# ============================================
# K3S SERVER (MASTER NODE) CONFIGURATION
# ============================================

# Tipo de máquina para el servidor K3s (control plane)
# Opciones: e2-medium (2 vCPUs, 4GB RAM) - Recomendado
#           e2-standard-2 (2 vCPUs, 8GB RAM) - Para producción
k3s_server_machine_type = "e2-medium"

# ============================================
# K3S AGENTS (WORKER NODES) CONFIGURATION
# ============================================

# Tipo de máquina para los agentes K3s (workers del autoscaling group)
# Opciones: e2-small (2 vCPUs, 2GB RAM) - Recomendado para K3s
#           e2-micro (2 vCPUs, 1GB RAM) - Muy limitado, no recomendado
#           e2-medium (2 vCPUs, 4GB RAM) - Para cargas más pesadas
agent_machine_type = "e2-small"

# ============================================
# AUTOSCALING CONFIGURATION
# ============================================

# Número mínimo de instancias worker en el grupo de autoscaling
# Valor recomendado: 2 (para alta disponibilidad)
min_replicas = 2

# Número máximo de instancias worker en el grupo de autoscaling
# Ajustar según presupuesto y carga esperada
max_replicas = 5

# Target de utilización de CPU para autoscaling (0.0 - 1.0)
# 0.6 = 60% - Cuando se supere este valor, se crearán nuevas instancias
cpu_target = 0.6

# ============================================
# DEPLOYMENT CONFIGURATION
# ============================================

# Habilitar deployment automático de Coarlumini después de crear infraestructura
# true = Terraform ejecutará automáticamente build-and-push.sh y deploy-to-k3s.sh
# false = Deberás ejecutar los scripts manualmente
enable_auto_deploy = true

# Tiempo de espera (en segundos) para que K3s se inicialice antes de desplegar
# Recomendado: 180 (3 minutos)
# Si el deployment falla, aumentar a 240 o 300
deploy_wait_time = 180

# ============================================
# NOTAS IMPORTANTES
# ============================================

# 1. Asegúrate de tener las APIs habilitadas:
#    gcloud services enable compute.googleapis.com
#    gcloud services enable storage.googleapis.com
#    gcloud services enable containerregistry.googleapis.com

# 2. Asegúrate de estar autenticado:
#    gcloud auth login
#    gcloud auth application-default login

# 3. Costos estimados (us-central1):
#    - K3s Server (e2-medium): ~$24/mes
#    - Agents (2-5 x e2-small): ~$24-60/mes
#    - Load Balancer: ~$18/mes
#    - Storage/Egress: ~$10/mes
#    TOTAL: ~$76-112/mes

# 4. Para desarrollo/testing, considera:
#    min_replicas = 1
#    max_replicas = 2
#    k3s_server_machine_type = "e2-small"
