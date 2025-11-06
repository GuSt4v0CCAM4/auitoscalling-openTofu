# Autoscaling Demo + Coarlumini K3s Integration

Esta es la integración completa de la infraestructura de autoscaling de Google Compute Engine con Kubernetes (K3s) para desplegar la aplicación Coarlumini.

## 🎯 ¿Qué hace este proyecto?

Combina:
- ✅ **Infraestructura de autoscaling**: Load Balancer + Instance Group (2-5 instancias)
- ✅ **Cluster Kubernetes K3s**: 1 master + N workers (autoscaling)
- ✅ **Aplicación Coarlumini**: Laravel + Vue.js + MySQL
- ✅ **Deployment automatizado**: Terraform provisioners que construyen y despliegan todo

## 🏗️ Arquitectura

```
Internet
    │
    ├──────> Load Balancer HTTP Global
    │             │
    │             ├──> K3s Agent 1 (Worker) ──┐
    │             ├──> K3s Agent 2 (Worker) ──┤ Autoscaling (2-5)
    │             └──> K3s Agent N (Worker) ──┤
    │                                          │
    └──────> K3s Server (Master - Fijo) ──────┘
                  │
                  └──> Kubernetes Cluster
                         ├─> MySQL Database
                         ├─> Laravel Backend  
                         └─> Vue.js Frontend
```

### Componentes

1. **K3s Server (Master)**: Instancia fija `e2-medium` que controla el cluster
2. **K3s Agents (Workers)**: Grupo de autoscaling `e2-small` (2-5 instancias)
3. **Load Balancer**: Distribuye tráfico HTTP entre los workers
4. **Cloud Storage**: Almacena manifiestos de Kubernetes
5. **Container Registry**: Almacena imágenes Docker

## 📋 Requisitos Previos

### Google Cloud Platform

1. **Proyecto de GCP** con facturación habilitada
2. **APIs habilitadas**:
   ```bash
   gcloud services enable compute.googleapis.com
   gcloud services enable storage.googleapis.com
   gcloud services enable containerregistry.googleapis.com
   ```

3. **Autenticación**:
   ```bash
   gcloud auth login
   gcloud config set project TU-PROJECT-ID
   ```

### Herramientas Locales

- [Terraform](https://www.terraform.io/downloads) o [OpenTofu](https://opentofu.org/) >= 1.6
- [gcloud CLI](https://cloud.google.com/sdk/docs/install)
- [Docker](https://docs.docker.com/get-docker/)

## 🚀 Deployment Rápido

### 1. Configurar Variables

Crea el archivo `terraform.tfvars`:

```hcl
project_id = "tu-proyecto-gcp"
region     = "us-central1"

# Opcional: personalizar configuración
k3s_server_machine_type = "e2-medium"  # Master: 2 vCPUs, 4GB RAM
agent_machine_type      = "e2-small"   # Workers: 2 vCPUs, 2GB RAM
min_replicas            = 2            # Mínimo de workers
max_replicas            = 5            # Máximo de workers
cpu_target              = 0.6          # 60% CPU para autoscalar
enable_auto_deploy      = true         # Deployment automático
deploy_wait_time        = 180          # Segundos de espera
```

### 2. Inicializar Terraform

```bash
cd autoscaling-demo
terraform init
```

### 3. Ver Plan de Ejecución

```bash
terraform plan -var="project_id=tu-proyecto-gcp"
```

### 4. Desplegar Todo (¡Un Solo Comando!)

```bash
terraform apply -var="project_id=tu-proyecto-gcp"
```

**Esto automáticamente:**
1. ✅ Crea infraestructura de red y firewall
2. ✅ Crea servidor K3s master
3. ✅ Crea grupo de autoscaling con workers K3s
4. ✅ Crea Load Balancer
5. ✅ Construye imágenes Docker de Coarlumini
6. ✅ Sube imágenes a Google Container Registry
7. ✅ Despliega Coarlumini en Kubernetes

**Tiempo estimado:** 12-15 minutos

### 5. Acceder a la Aplicación

```bash
# Ver outputs de Terraform
terraform output

# Obtener URLs
terraform output access_urls
```

Accede a:
- **Load Balancer**: `http://<LOAD_BALANCER_IP>`
- **Directo al servidor**: `http://<SERVER_IP>:30080`

## 📊 Flujo de Deployment Detallado

```
┌─────────────────────────────────────────────────────────┐
│  1. terraform apply                                     │
└─────────────────┬───────────────────────────────────────┘
                  │
      ┌───────────┴───────────┐
      │                       │
      ▼                       ▼
┌──────────────┐    ┌──────────────────┐
│  Infraestr.  │    │  K3s Server      │
│  - Network   │    │  - Instala K3s   │
│  - Firewall  │    │  - Descarga      │
│  - GCS       │    │    manifiestos   │
└──────┬───────┘    └────────┬─────────┘
       │                     │
       │    ┌────────────────┘
       │    │
       ▼    ▼
┌──────────────────────┐
│  K3s Agents          │
│  - Instance Group    │
│  - Se unen al master │
│  - Autoscaling 2-5   │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  2. Provisioner local-exec           │
│     (Espera 3 min)                   │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  3. scripts/build-and-push.sh        │
│     - Construye 3 imágenes Docker    │
│     - Sube a GCR                     │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  4. scripts/deploy-to-k3s.sh         │
│     - SSH al servidor K3s            │
│     - kubectl apply manifiestos      │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  ✓ Coarlumini corriendo en K3s       │
│     - Database (MySQL)               │
│     - Backend (Laravel)              │
│     - Frontend (Vue.js)              │
└──────────────────────────────────────┘
```

## 🔧 Gestión y Operación

### SSH al Servidor K3s

```bash
# Usando gcloud
gcloud compute ssh k3s-master-server --zone=us-central1-a

# O usando el output de Terraform
terraform output ssh_commands
```

### Ver Estado del Cluster

```bash
# Dentro del servidor K3s
kubectl get nodes
kubectl get pods -n coarlumini
kubectl get services -n coarlumini
kubectl get all -n coarlumini
```

### Ver Logs de Aplicación

```bash
# Logs del backend
kubectl logs -l app=coarlumini-backend -n coarlumini --tail=100 -f

# Logs del frontend
kubectl logs -l app=coarlumini-frontend -n coarlumini -f

# Logs de la base de datos
kubectl logs -l app=coarlumini-database -n coarlumini -f
```

### Escalar Componentes

#### Escalar Pods (HPA automático ya configurado)

```bash
# Escalar backend manualmente
kubectl scale deployment coarlumini-backend -n coarlumini --replicas=3

# Ver estado del HPA
kubectl get hpa -n coarlumini

# Describir HPA
kubectl describe hpa coarlumini-backend -n coarlumini
```

#### Escalar Instancias (Autoscaler de GCE)

```bash
# Ver instancias actuales
gcloud compute instance-groups managed list-instances web-group-manager \
    --zone=us-central1-a

# Cambiar límites de autoscaling
gcloud compute instance-groups managed set-autoscaling web-group-manager \
    --zone=us-central1-a \
    --min-num-replicas=3 \
    --max-num-replicas=10
```

### Reiniciar Componentes

```bash
# Reiniciar backend
kubectl rollout restart deployment/coarlumini-backend -n coarlumini

# Ver progreso del rollout
kubectl rollout status deployment/coarlumini-backend -n coarlumini

# Reiniciar frontend
kubectl rollout restart deployment/coarlumini-frontend -n coarlumini
```

### Redesplegar Aplicación

Si solo quieres redesplegar sin reconstruir infraestructura:

```bash
# Opción 1: Desde tu máquina local
cd autoscaling-demo
export PROJECT_ID="tu-proyecto"
export K3S_SERVER_NAME="k3s-master-server"
export ZONE="us-central1-a"

# Solo rebuild de imágenes
./scripts/build-and-push.sh

# Solo redeploy
./scripts/deploy-to-k3s.sh

# Opción 2: Desde el servidor K3s
gcloud compute ssh k3s-master-server --zone=us-central1-a
sudo /root/deploy-coarlumini.sh
```

## 🔍 Monitoreo

### Ver Métricas del Cluster

```bash
# En el servidor K3s
kubectl top nodes
kubectl top pods -n coarlumini
```

### Ver Eventos

```bash
# Eventos del namespace
kubectl get events -n coarlumini --sort-by='.lastTimestamp'

# Eventos de un pod específico
kubectl describe pod <pod-name> -n coarlumini
```

### Ver Estado de Autoscaling

```bash
# Estado del autoscaler de GCE
gcloud compute instance-groups managed describe web-group-manager \
    --zone=us-central1-a

# Histórico de autoscaling
gcloud logging read "resource.type=gce_autoscaler" --limit 50
```

## 🛠️ Solución de Problemas

### Pods no inician

```bash
# Ver estado detallado
kubectl describe pod <pod-name> -n coarlumini

# Ver eventos
kubectl get events -n coarlumini

# Verificar imágenes en GCR
gcloud container images list --repository=gcr.io/PROJECT_ID
```

### Imágenes no se descargan

```bash
# Verificar permisos del nodo
gcloud compute ssh <instance-name> --zone=us-central1-a
docker pull gcr.io/PROJECT_ID/coarlumini-backend:latest

# Re-autenticar Docker con GCR
gcloud auth configure-docker gcr.io
```

### Agentes no se unen al cluster

```bash
# Ver logs de startup del agente
gcloud compute instances get-serial-port-output <agent-name> \
    --zone=us-central1-a

# Verificar conectividad al master
gcloud compute ssh <agent-name> --zone=us-central1-a
curl -k https://<master-ip>:6443
```

### Base de datos no responde

```bash
# Ver logs de MySQL
kubectl logs -l app=coarlumini-database -n coarlumini

# Entrar al pod de database
kubectl exec -it <db-pod-name> -n coarlumini -- bash
mysql -u root -p
```

### Deployment automático falló

Si el provisioner falló, puedes ejecutar manualmente:

```bash
# Desde autoscaling-demo/
export PROJECT_ID="tu-proyecto"

# Build de imágenes
./scripts/build-and-push.sh

# Deploy
export K3S_SERVER_NAME="k3s-master-server"
export ZONE="us-central1-a"
./scripts/deploy-to-k3s.sh
```

## 🔐 Seguridad

### Obtener Credenciales Sensibles

```bash
# Token K3s
terraform output k3s_token

# Password de Database
terraform output db_password

# Laravel App Key
terraform output app_key
```

### Configurar Kubeconfig Local

```bash
# Obtener kubeconfig del servidor
terraform output kubectl_config_command | bash

# O manualmente
gcloud compute ssh k3s-master-server --zone=us-central1-a \
  --command='sudo cat /etc/rancher/k3s/k3s.yaml' > kubeconfig.yaml

# Reemplazar 127.0.0.1 con la IP pública del servidor
SERVER_IP=$(terraform output -raw k3s_server_ip)
sed -i "s/127.0.0.1/$SERVER_IP/g" kubeconfig.yaml

# Usar kubeconfig
export KUBECONFIG=./kubeconfig.yaml
kubectl get nodes
```

## 📝 Estructura de Archivos

```
autoscaling-demo/
├── main.tf                          # Infraestructura principal con K3s
├── variables.tf                     # Variables de configuración
├── outputs.tf                       # Outputs (IPs, URLs, comandos)
├── terraform.tfvars                 # TUS valores de configuración
├── scripts/
│   ├── k3s-server-init.sh          # Inicialización del master K3s
│   ├── k3s-agent-init.sh           # Inicialización de workers K3s
│   ├── build-and-push.sh           # Build de imágenes Docker
│   └── deploy-to-k3s.sh            # Deploy de la aplicación
├── *-original.tf.backup            # Backups de archivos originales
└── README.md                        # Este archivo

coarlumini/                          # (Sin cambios)
├── k8s/                            # Manifiestos Kubernetes (reutilizados)
├── frontend/                       # Frontend Vue.js
├── database/                       # Database MySQL
├── Dockerfile                      # Backend Laravel
└── ...
```

## 🧹 Limpieza

### Destruir Toda la Infraestructura

```bash
cd autoscaling-demo
terraform destroy -var="project_id=tu-proyecto-gcp"
```

### Solo Eliminar la Aplicación (mantener infraestructura)

```bash
gcloud compute ssh k3s-master-server --zone=us-central1-a
kubectl delete namespace coarlumini
```

## 💰 Estimación de Costos

Con configuración por defecto en `us-central1`:

| Recurso | Tipo | Costo/mes (aprox) |
|---------|------|-------------------|
| K3s Server | e2-medium (siempre activo) | ~$24 |
| K3s Agents | 2-5 x e2-small | ~$24-60 |
| Load Balancer | HTTP Global | ~$18 |
| Discos persistentes | 50GB + 30GB x agents | ~$10-20 |
| Egreso de red | Variable | ~$5-10 |
| **TOTAL** | | **$81-132/mes** |

> 💡 **Tip**: Para reducir costos en desarrollo, usa `min_replicas=1` y `max_replicas=2`

## 🔄 Actualizar la Aplicación

### Actualizar Código de Coarlumini

```bash
# 1. Actualizar código en ../coarlumini/
# 2. Reconstruir imágenes
cd autoscaling-demo
export PROJECT_ID="tu-proyecto"
./scripts/build-and-push.sh

# 3. Redesplegar
export K3S_SERVER_NAME="k3s-master-server"
export ZONE="us-central1-a"
./scripts/deploy-to-k3s.sh
```

### Actualizar Manifiestos K8s

```bash
# 1. Editar manifiestos en ../coarlumini/k8s/
# 2. Re-aplicar con Terraform (sube a GCS)
terraform apply -var="project_id=tu-proyecto"

# 3. Aplicar en el cluster
gcloud compute ssh k3s-master-server --zone=us-central1-a
cd /root/k8s-manifests
gsutil -m cp -r "gs://BUCKET_NAME/*" .
kubectl apply -f . -n coarlumini
```

## 📚 Referencias

- [K3s Documentation](https://docs.k3s.io/)
- [Terraform GCP Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [GCE Autoscaling](https://cloud.google.com/compute/docs/autoscaler)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Google Container Registry](https://cloud.google.com/container-registry/docs)

## 🤝 Contribuir

Este proyecto integra:
- Infraestructura base de `autoscaling-demo`
- Aplicación de `coarlumini`

Para modificar:
1. **Infraestructura**: Edita archivos `.tf`
2. **Scripts**: Edita archivos en `scripts/`
3. **Aplicación**: Edita archivos en `../coarlumini/`

## ⚠️ Notas Importantes

1. **Primera ejecución**: El primer `terraform apply` tarda ~12-15 minutos
2. **Credenciales**: Las credenciales sensibles se generan automáticamente
3. **Persistencia**: Los datos de MySQL persisten en discos (sobreviven recreaciones)
4. **Autoscaling**: Funciona a dos niveles:
   - **Pods**: HPA escala réplicas según CPU
   - **Instancias**: Autoscaler de GCE escala workers según carga
5. **Health checks**: Nginx en puerto 80 para que el LB detecte instancias sanas

## 🎓 Aprendizajes

Este proyecto demuestra:
- ✅ Infrastructure as Code con Terraform/OpenTofu
- ✅ Kubernetes en infraestructura de autoscaling
- ✅ Multi-tier application deployment
- ✅ CI/CD con Terraform provisioners
- ✅ Container registry y Docker builds
- ✅ Load balancing y autoscaling en GCP
- ✅ Gestión de secretos con Terraform random providers

---

**¿Problemas?** Revisa la sección de [Solución de Problemas](#-solución-de-problemas)

**¿Preguntas?** Revisa los [outputs de Terraform](#5-acceder-a-la-aplicación) para comandos útiles