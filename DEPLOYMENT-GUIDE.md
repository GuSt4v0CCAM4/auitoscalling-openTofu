# 🚀 Guía de Deployment Automatizado - Coarlumini en K3s

Esta guía te llevará paso a paso para desplegar automáticamente la aplicación Coarlumini en un cluster K3s con autoscaling en Google Cloud Platform.

## ✅ Cambios Realizados para K3s

Los siguientes archivos han sido actualizados para compatibilidad con K3s:

### **Manifiestos de Kubernetes**
- ✅ `coarlumini/k8s/03-database-pvc.yaml` - `storageClassName: local-path`
- ✅ `coarlumini/k8s/07-backend-pvc.yaml` - `storageClassName: local-path`
- ✅ `coarlumini/k8s/10-frontend-pvc.yaml` - `storageClassName: local-path`

### **Scripts de Inicialización**
- ✅ `scripts/k3s-server-init.sh` - Descarga imágenes Docker automáticamente en el master
- ✅ `scripts/k3s-agent-init.sh` - Descarga imágenes Docker automáticamente en workers
- ✅ `main.tf` - Service Account con permisos para Artifact Registry

### **Nuevos Scripts**
- ✅ `scripts/validate-setup.sh` - Valida que todo esté configurado correctamente

## 📋 Prerrequisitos

Antes de comenzar, asegúrate de tener:

### 1. Herramientas Instaladas
```bash
# Verificar instalaciones
gcloud --version
docker --version
terraform --version  # o tofu --version
```

### 2. Cuenta de Google Cloud
- Proyecto de GCP creado
- Facturación habilitada
- APIs necesarias habilitadas

### 3. Autenticación
```bash
# Autenticar con gcloud
gcloud auth login

# Configurar proyecto
gcloud config set project TU-PROJECT-ID

# Autenticar Docker con GCR
gcloud auth configure-docker gcr.io

# Autenticación para Terraform
gcloud auth application-default login
```

## 🎯 Deployment en 5 Pasos

### **Paso 1: Validar Setup**

```bash
cd ~/Documents/Universidad/5B_CloudComputing/autoscaling-demo

# Ejecutar validación
./scripts/validate-setup.sh
```

Este script verifica:
- ✅ Herramientas instaladas (gcloud, docker, terraform)
- ✅ Autenticación de gcloud
- ✅ Estructura de archivos del proyecto
- ✅ Manifiestos de Kubernetes correctos
- ✅ Dockerfiles presentes
- ✅ APIs de GCP habilitadas

**Si hay errores, corrígelos antes de continuar.**

### **Paso 2: Configurar Variables**

```bash
# Copiar archivo de ejemplo (si no existe)
cp terraform.tfvars.example terraform.tfvars

# Editar con tus valores
nano terraform.tfvars
```

**Configuración mínima requerida:**
```hcl
project_id = "tu-proyecto-gcp"
region     = "us-central1"
```

**Configuración recomendada:**
```hcl
project_id = "tu-proyecto-gcp"
region     = "us-central1"

# Tipos de máquinas
k3s_server_machine_type = "e2-medium"  # Master: 2 vCPUs, 4GB RAM
agent_machine_type      = "e2-small"   # Workers: 2 vCPUs, 2GB RAM

# Autoscaling
min_replicas = 2  # Mínimo de workers
max_replicas = 5  # Máximo de workers
cpu_target   = 0.6  # 60% CPU para escalar

# Deployment automático
enable_auto_deploy = true
deploy_wait_time   = 180  # Segundos de espera antes de desplegar
```

### **Paso 3: Habilitar APIs de GCP**

```bash
# Habilitar todas las APIs necesarias
gcloud services enable compute.googleapis.com \
  storage-api.googleapis.com \
  containerregistry.googleapis.com \
  artifactregistry.googleapis.com \
  --project=tu-proyecto-gcp
```

### **Paso 4: Inicializar Terraform**

```bash
# Inicializar (solo la primera vez)
terraform init

# Ver plan de ejecución
terraform plan -var-file=terraform.tfvars
```

### **Paso 5: Desplegar Todo**

```bash
# ¡UN SOLO COMANDO DESPLIEGA TODO!
terraform apply -var-file=terraform.tfvars
```

Cuando pregunte `Do you want to perform these actions?`, escribe `yes` y presiona Enter.

## ⏱️ ¿Qué Sucede Automáticamente?

El deployment automático ejecuta estos pasos en orden:

```
┌─────────────────────────────────────────┐
│ 1. INFRAESTRUCTURA (2-3 min)           │
├─────────────────────────────────────────┤
│ - Red VPC                               │
│ - Subredes                              │
│ - Reglas de Firewall                    │
│ - Service Account                       │
│ - Cloud Storage bucket                  │
│ - Load Balancer                         │
└─────────────────────────────────────────┘
            ↓
┌─────────────────────────────────────────┐
│ 2. K3S MASTER SERVER (3-4 min)         │
├─────────────────────────────────────────┤
│ - Instancia e2-medium                   │
│ - Instala Docker                        │
│ - Instala K3s server                    │
│ - Instala Helm & nginx-ingress          │
│ - Descarga manifiestos desde GCS        │
│ - DESCARGA IMÁGENES DOCKER DE GCR       │
│ - Configura namespace y secrets         │
└─────────────────────────────────────────┘
            ↓
┌─────────────────────────────────────────┐
│ 3. K3S WORKER NODES (2-3 min)          │
├─────────────────────────────────────────┤
│ - 2-5 instancias e2-small               │
│ - Instala Docker                        │
│ - Instala K3s agent                     │
│ - Se une al cluster                     │
│ - DESCARGA IMÁGENES DOCKER DE GCR       │
│ - Configura health checks               │
└─────────────────────────────────────────┘
            ↓
┌─────────────────────────────────────────┐
│ 4. BUILD IMÁGENES DOCKER (5-7 min)     │
├─────────────────────────────────────────┤
│ - Construye coarlumini-database         │
│ - Construye coarlumini-backend          │
│ - Construye coarlumini-frontend         │
│ - Sube a gcr.io/PROJECT_ID/             │
└─────────────────────────────────────────┘
            ↓
┌─────────────────────────────────────────┐
│ 5. DEPLOY A KUBERNETES (3-5 min)       │
├─────────────────────────────────────────┤
│ - Despliega MySQL database              │
│ - Despliega Laravel backend             │
│ - Despliega Vue.js frontend             │
│ - Configura servicios NodePort          │
│ - Configura HPA (autoscaling)           │
└─────────────────────────────────────────┘
            ↓
        ✅ LISTO
   (12-15 minutos total)
```

## 🎉 Acceder a la Aplicación

Una vez completado el deployment:

```bash
# Ver outputs de Terraform
terraform output

# URLs de acceso
terraform output access_urls
```

Obtendrás dos formas de acceder:

### **Opción 1: Load Balancer (Recomendado)**
```
http://<LOAD_BALANCER_IP>
```

### **Opción 2: Directo al Servidor K3s**
```
http://<SERVER_IP>:30080
```

## 🔍 Verificar el Deployment

### **SSH al Servidor K3s**

```bash
# Desde tu máquina local
gcloud compute ssh k3s-master-server --zone=us-central1-a --project=tu-proyecto-gcp

# Convertirse en root
sudo su -

# Ver nodos del cluster
kubectl get nodes

# Ver pods de Coarlumini
kubectl get pods -n coarlumini

# Ver servicios
kubectl get svc -n coarlumini

# Ver todos los recursos
kubectl get all -n coarlumini
```

### **Verificar que las Imágenes Están en los Nodos**

```bash
# En el servidor master
docker images | grep coarlumini

# En un worker (conectarse primero)
gcloud compute ssh k3s-agent-xxx --zone=us-central1-a
docker images | grep coarlumini
```

Deberías ver 3 imágenes:
```
gcr.io/tu-proyecto/coarlumini-database    latest
gcr.io/tu-proyecto/coarlumini-backend     latest
gcr.io/tu-proyecto/coarlumini-frontend    latest
```

### **Ver Logs de los Pods**

```bash
# Logs del database
kubectl logs -l app=coarlumini-database -n coarlumini -f

# Logs del backend
kubectl logs -l app=coarlumini-backend -n coarlumini -f

# Logs del frontend
kubectl logs -l app=coarlumini-frontend -n coarlumini -f
```

## 🔧 Comandos Útiles

### **Estado del Cluster**

```bash
# Ver nodos
kubectl get nodes -o wide

# Ver pods en tiempo real
watch kubectl get pods -n coarlumini -o wide

# Ver PVCs (deben estar Bound)
kubectl get pvc -n coarlumini

# Ver eventos
kubectl get events -n coarlumini --sort-by='.lastTimestamp'
```

### **Escalar Manualmente**

```bash
# Escalar pods del backend
kubectl scale deployment coarlumini-backend -n coarlumini --replicas=3

# Ver HPA (Horizontal Pod Autoscaler)
kubectl get hpa -n coarlumini

# Describir HPA
kubectl describe hpa coarlumini-backend -n coarlumini
```

### **Reiniciar Componentes**

```bash
# Reiniciar backend
kubectl rollout restart deployment/coarlumini-backend -n coarlumini

# Ver progreso
kubectl rollout status deployment/coarlumini-backend -n coarlumini

# Reiniciar frontend
kubectl rollout restart deployment/coarlumini-frontend -n coarlumini
```

### **Redesplegar Aplicación**

Si solo quieres redesplegar la aplicación (sin recrear infraestructura):

```bash
# Opción 1: Desde tu máquina local
cd autoscaling-demo
export PROJECT_ID="tu-proyecto-gcp"
export K3S_SERVER_NAME="k3s-master-server"
export ZONE="us-central1-a"

# Reconstruir imágenes
./scripts/build-and-push.sh

# Redesplegar
./scripts/deploy-to-k3s.sh

# Opción 2: Desde el servidor K3s
gcloud compute ssh k3s-master-server --zone=us-central1-a
sudo /root/deploy-coarlumini.sh
```

## 🐛 Solución de Problemas

### **Problema: Pods en ImagePullBackOff**

**Causa:** Las imágenes no se descargaron en los nodos.

**Solución:**
```bash
# Conectarse al nodo afectado
gcloud compute ssh <node-name> --zone=us-central1-a

# Autenticar Docker
gcloud auth configure-docker gcr.io

# Descargar imágenes manualmente
docker pull gcr.io/tu-proyecto/coarlumini-database:latest
docker pull gcr.io/tu-proyecto/coarlumini-backend:latest
docker pull gcr.io/tu-proyecto/coarlumini-frontend:latest

# Reiniciar pods
kubectl delete pod -l app=coarlumini-frontend -n coarlumini
```

### **Problema: PVCs en Pending**

**Causa:** StorageClass incorrecto o no existe.

**Solución:**
```bash
# Verificar StorageClass
kubectl get storageclass

# Crear si no existe
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

# Eliminar y recrear PVCs
kubectl delete pvc --all -n coarlumini
kubectl apply -f /root/k8s-manifests/03-database-pvc.yaml
kubectl apply -f /root/k8s-manifests/07-backend-pvc.yaml
kubectl apply -f /root/k8s-manifests/10-frontend-pvc.yaml
```

### **Problema: Backend en Init:0/1**

**Causa:** Esperando a que la database esté lista.

**Solución:**
```bash
# Ver logs del init container
POD_NAME=$(kubectl get pods -n coarlumini -l app=coarlumini-backend -o jsonpath='{.items[0].metadata.name}')
kubectl logs $POD_NAME -n coarlumini -c init-app

# Verificar que database está running
kubectl get pods -l app=coarlumini-database -n coarlumini

# Verificar servicio de database
kubectl get svc coarlumini-database-service -n coarlumini

# Test de conectividad
kubectl run -it --rm debug --image=busybox --restart=Never -n coarlumini -- nc -zv coarlumini-database-service 3306
```

### **Problema: No puedo acceder desde el navegador**

**Causa:** Puerto no abierto en el firewall.

**Solución:**
```bash
# Verificar regla de firewall
gcloud compute firewall-rules describe web-firewall --project=tu-proyecto-gcp

# Verificar tags de la instancia
gcloud compute instances describe k3s-master-server \
  --zone=us-central1-a \
  --format="get(tags.items)"

# Test desde el servidor
curl -I http://localhost:30080
```

## 🧹 Limpiar Recursos

### **Eliminar Solo la Aplicación**

```bash
# SSH al servidor
gcloud compute ssh k3s-master-server --zone=us-central1-a
sudo kubectl delete namespace coarlumini
```

### **Eliminar Toda la Infraestructura**

```bash
# Desde tu máquina local
cd autoscaling-demo
terraform destroy -var-file=terraform.tfvars
```

**ADVERTENCIA:** Esto eliminará:
- ❌ Todas las instancias (master + workers)
- ❌ Load Balancer
- ❌ Discos persistentes (se perderán los datos)
- ❌ Imágenes en GCR (se mantienen)
- ❌ Cloud Storage bucket

## 💰 Estimación de Costos

Con la configuración por defecto en `us-central1`:

| Recurso | Especificación | Costo/mes |
|---------|---------------|-----------|
| K3s Master | 1x e2-medium (siempre activo) | ~$24 |
| K3s Workers | 2-5x e2-small (autoscaling) | ~$24-60 |
| Load Balancer | HTTP Global | ~$18 |
| Discos | 50GB + 30GB × workers | ~$10-20 |
| Egreso red | Variable según uso | ~$5-10 |
| **TOTAL** | | **~$81-132/mes** |

### **Reducir Costos para Desarrollo**

```hcl
# En terraform.tfvars
min_replicas            = 1
max_replicas            = 2
k3s_server_machine_type = "e2-small"
agent_machine_type      = "e2-micro"  # Mínimo absoluto
```

Costo reducido: **~$40-50/mes**

## 📚 Referencias

- [Documentación de K3s](https://docs.k3s.io/)
- [Terraform GCP Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [GCE Autoscaling](https://cloud.google.com/compute/docs/autoscaler)
- [Kubernetes Docs](https://kubernetes.io/docs/)
- [Google Container Registry](https://cloud.google.com/container-registry/docs)

## 🎓 Arquitectura del Proyecto

```
autoscaling-demo/
├── main.tf                    # Infraestructura principal
├── variables.tf               # Variables configurables
├── outputs.tf                 # Outputs (IPs, URLs, comandos)
├── terraform.tfvars           # TU configuración
├── scripts/
│   ├── validate-setup.sh      # ✨ Validación pre-deployment
│   ├── k3s-server-init.sh     # ✨ Init master + descarga imágenes
│   ├── k3s-agent-init.sh      # ✨ Init workers + descarga imágenes
│   ├── build-and-push.sh      # Build de imágenes Docker
│   └── deploy-to-k3s.sh       # Deploy de Coarlumini
└── DEPLOYMENT-GUIDE.md        # Esta guía

coarlumini/
├── k8s/                       # ✨ Manifiestos con local-path
│   ├── 00-namespace.yaml
│   ├── 01-configmap.yaml
│   ├── 02-secrets.yaml
│   ├── 03-database-pvc.yaml   # ✅ storageClassName: local-path
│   ├── 04-database-deployment.yaml
│   ├── 05-database-service.yaml
│   ├── 06-backend-deployment.yaml
│   ├── 07-backend-pvc.yaml    # ✅ storageClassName: local-path
│   ├── 08-backend-service.yaml
│   ├── 09-frontend-deployment.yaml
│   ├── 10-frontend-pvc.yaml   # ✅ storageClassName: local-path
│   ├── 11-nginx-config.yaml
│   ├── 12-frontend-service.yaml
│   ├── 13-ingress.yaml
│   └── 14-horizontal-escalling.yaml
├── Dockerfile                 # Backend Laravel
├── database/Dockerfile        # Database MySQL
└── frontend/Dockerfile        # Frontend Vue.js
```

## ✅ Checklist de Deployment

Antes de ejecutar `terraform apply`, verifica:

- [ ] Herramientas instaladas (gcloud, docker, terraform)
- [ ] Autenticado con gcloud
- [ ] Docker configurado para GCR
- [ ] `terraform.tfvars` configurado con tu project_id
- [ ] APIs de GCP habilitadas
- [ ] Ejecutado `./scripts/validate-setup.sh` sin errores
- [ ] Tienes presupuesto suficiente (~$80-130/mes)

Una vez completado el deployment:

- [ ] Pods en estado `Running`
- [ ] PVCs en estado `Bound`
- [ ] Imágenes Docker en todos los nodos
- [ ] Aplicación accesible desde el navegador
- [ ] Load Balancer funcionando

---

**¿Problemas?** Revisa la sección de **Solución de Problemas** o ejecuta el script de diagnóstico en el servidor:

```bash
gcloud compute ssh k3s-master-server --zone=us-central1-a
sudo kubectl get all -n coarlumini
sudo kubectl describe pods -n coarlumini
```

**¡Listo para deployar! 🚀**