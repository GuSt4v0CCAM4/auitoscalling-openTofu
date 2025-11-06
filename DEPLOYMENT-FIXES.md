# 🔧 CORRECCIONES DE DEPLOYMENT - K3S + GCR

Este documento describe las correcciones aplicadas al sistema de deployment para evitar errores comunes relacionados con autenticación de GCR y uso de containerd en K3s.

---

## 📋 PROBLEMAS CORREGIDOS

### 1. **Error de Autenticación con GCR (403 Forbidden)**
**Problema Original:**
```
Failed to pull image: failed to authorize: failed to fetch anonymous token: 403 Forbidden
```

**Causa:**
- K3s no podía autenticarse con Google Container Registry (GCR)
- Falta de ImagePullSecret en Kubernetes
- La Service Account no tenía permisos correctos

**Solución Aplicada:**
- ✅ Creación automática de ImagePullSecret con credenciales de Service Account
- ✅ Configuración de permisos `storage.objectViewer` para la Service Account
- ✅ Agregado de `imagePullSecrets` a todos los deployments

---

### 2. **Uso de Docker en lugar de Containerd**
**Problema Original:**
```
permission denied while trying to connect to the Docker daemon socket
```

**Causa:**
- K3s usa **containerd** como runtime, no Docker
- Los scripts intentaban usar `docker pull` en lugar de `crictl pull`

**Solución Aplicada:**
- ✅ Cambiado `docker pull` → `crictl pull` en todos los scripts
- ✅ Configuración de `/etc/crictl.yaml` en master y workers
- ✅ Uso de `crictl images` para verificar imágenes descargadas

---

### 3. **Tag Incorrecto en Imagen de Frontend**
**Problema Original:**
```
Failed to pull image "gcr.io/cloudcomputingunsa/coarlumini-frontend:latestst"
```

**Causa:**
- Typo en el manifiesto: `latestst` en lugar de `latest`

**Solución Aplicada:**
- ✅ Corrección automática del typo en scripts de inicialización
- ✅ Validación del tag en script de pre-deployment

---

### 4. **ConfigMap nginx-config No Aplicado**
**Problema Original:**
```
MountVolume.SetUp failed for volume "nginx-config": configmap "nginx-config" not found
```

**Causa:**
- El ConfigMap no se aplicaba antes del deployment del frontend
- Orden incorrecto en la aplicación de manifiestos

**Solución Aplicada:**
- ✅ Aplicación explícita de `11-nginx-config.yaml` antes del frontend
- ✅ Orden correcto de aplicación de manifiestos en `deploy-coarlumini.sh`

---

### 5. **Nodos en Estado NotReady**
**Problema Original:**
```
k3s-agent-608c   NotReady   <none>   3h53m
```

**Causa:**
- Workers no podían comunicarse con el master
- Problemas de inicialización de los agentes

**Solución Aplicada:**
- ✅ Configuración correcta de containerd en workers
- ✅ Descarga proactiva de imágenes en workers con `crictl pull`
- ✅ Configuración de credenciales de GCR en workers

---

## 🛠️ ARCHIVOS MODIFICADOS

### Scripts de Inicialización

#### `scripts/k3s-server-init.sh`
**Cambios principales:**
1. **Creación de ImagePullSecret:**
   ```bash
   # Crear clave del service account
   gcloud iam service-accounts keys create "$KEY_FILE" \
       --iam-account="$SA_EMAIL"
   
   # Crear ImagePullSecret en Kubernetes
   kubectl create secret docker-registry gcr-json-key \
       --docker-server=gcr.io \
       --docker-username=_json_key \
       --docker-password="$(cat $KEY_FILE)" \
       -n coarlumini
   ```

2. **Uso de crictl en lugar de docker:**
   ```bash
   # ANTES: docker pull gcr.io/...
   # AHORA: crictl pull gcr.io/...
   crictl pull gcr.io/${PROJECT_ID}/coarlumini-database:latest
   crictl pull gcr.io/${PROJECT_ID}/coarlumini-backend:latest
   crictl pull gcr.io/${PROJECT_ID}/coarlumini-frontend:latest
   ```

3. **Corrección automática de typos:**
   ```bash
   # Corregir typo común latestst -> latest
   sed -i "s|coarlumini-frontend:latestst|coarlumini-frontend:latest|g" \
       09-frontend-deployment.yaml
   ```

4. **Agregado de imagePullSecrets a deployments:**
   ```bash
   for file in 04-database-deployment.yaml 06-backend-deployment.yaml 09-frontend-deployment.yaml; do
       if ! grep -q "imagePullSecrets" "$file"; then
           sed -i '/^    spec:$/a\      imagePullSecrets:\n      - name: gcr-json-key' "$file"
       fi
   done
   ```

#### `scripts/k3s-agent-init.sh`
**Cambios principales:**
1. **Configuración de crictl:**
   ```bash
   cat > /etc/crictl.yaml <<EOF
   runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
   image-endpoint: unix:///run/k3s/containerd/containerd.sock
   timeout: 10
   debug: false
   EOF
   ```

2. **Descarga de imágenes con crictl:**
   ```bash
   for image in "${IMAGES[@]}"; do
       crictl pull "$image" || log "⚠ No se pudo descargar $image"
   done
   ```

### Manifiestos de Kubernetes

#### Todos los deployments (`04-`, `06-`, `09-`)
**Agregado de imagePullSecrets:**
```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: gcr-json-key  # <-- NUEVO
      containers:
        - name: ...
          image: gcr.io/cloudcomputingunsa/...
          imagePullPolicy: IfNotPresent
```

### Scripts Nuevos

#### `scripts/pre-deploy-validation.sh` (NUEVO)
Script de validación que verifica:
- ✅ Existencia de manifiestos críticos
- ✅ Presencia de imagePullSecrets en deployments
- ✅ Tags correctos de imágenes (sin typos)
- ✅ Existencia de imágenes en GCR
- ✅ Dockerfiles presentes
- ✅ Service Account configurada
- ✅ Scripts usando crictl en lugar de docker
- ✅ nginx-config.yaml presente

#### `scripts/fix-final.sh` (NUEVO)
Script de corrección que:
- ✅ Crea ImagePullSecret con credenciales de Service Account
- ✅ Actualiza deployments para usar el secret
- ✅ Corrige typos en tags de imágenes
- ✅ Aplica manifiestos en el orden correcto

#### `scripts/fix-frontend.sh` (NUEVO)
Script específico para corregir:
- ✅ Aplicación de nginx-config
- ✅ Corrección del tag latestst → latest
- ✅ Redeployment del frontend

---

## 🚀 USO DESPUÉS DE LAS CORRECCIONES

### Deployment desde Cero

```bash
cd autoscaling-demo

# 1. Validación pre-deployment (RECOMENDADO)
./scripts/pre-deploy-validation.sh

# 2. Deployment completo
export PROJECT_ID=cloudcomputingunsa
./scripts/full-deploy.sh
```

### Si ya Desplegaste y Tienes Errores

```bash
# Opción 1: Script de corrección completo
./scripts/fix-final.sh

# Opción 2: Solo corregir frontend
./scripts/fix-frontend.sh

# Opción 3: Limpiar y redesplegar desde cero
./scripts/clean-redeploy.sh
```

---

## ✅ VERIFICACIONES POST-DEPLOYMENT

### 1. Verificar ImagePullSecret
```bash
gcloud compute ssh k3s-master-server --zone=us-central1-a --command="
  sudo kubectl get secret gcr-json-key -n coarlumini
"
```

**Salida esperada:**
```
NAME            TYPE                             DATA   AGE
gcr-json-key    kubernetes.io/dockerconfigjson   1      5m
```

### 2. Verificar Imágenes en Containerd
```bash
gcloud compute ssh k3s-master-server --zone=us-central1-a --command="
  sudo crictl images | grep coarlumini
"
```

**Salida esperada:**
```
gcr.io/cloudcomputingunsa/coarlumini-backend     latest    ...
gcr.io/cloudcomputingunsa/coarlumini-database    latest    ...
gcr.io/cloudcomputingunsa/coarlumini-frontend    latest    ...
```

### 3. Verificar Estado de Pods
```bash
gcloud compute ssh k3s-master-server --zone=us-central1-a --command="
  sudo kubectl get pods -n coarlumini
"
```

**Salida esperada:**
```
NAME                                   READY   STATUS    RESTARTS   AGE
coarlumini-backend-xxx                 1/1     Running   0          5m
coarlumini-database-xxx                1/1     Running   0          5m
coarlumini-frontend-xxx                1/1     Running   0          5m
```

### 4. Verificar Deployment tiene ImagePullSecrets
```bash
gcloud compute ssh k3s-master-server --zone=us-central1-a --command="
  sudo kubectl get deployment coarlumini-frontend -n coarlumini -o yaml | grep -A 2 imagePullSecrets
"
```

**Salida esperada:**
```yaml
imagePullSecrets:
- name: gcr-json-key
```

---

## 🐛 TROUBLESHOOTING

### Problema: Pods en ImagePullBackOff

**Diagnóstico:**
```bash
kubectl describe pod <pod-name> -n coarlumini
```

**Posibles causas y soluciones:**

1. **ImagePullSecret faltante:**
   ```bash
   ./scripts/fix-final.sh
   ```

2. **Imagen no existe en GCR:**
   ```bash
   gcloud container images list --repository=gcr.io/cloudcomputingunsa
   ./scripts/build-and-push.sh
   ```

3. **Tag incorrecto:**
   ```bash
   ./scripts/fix-frontend.sh
   ```

### Problema: Error "configmap nginx-config not found"

**Solución:**
```bash
gcloud compute ssh k3s-master-server --zone=us-central1-a --command="
  sudo kubectl apply -f /root/k8s-manifests/11-nginx-config.yaml
  sudo kubectl delete pod -l app=coarlumini-frontend -n coarlumini
"
```

### Problema: No se pueden descargar imágenes con crictl

**Diagnóstico:**
```bash
sudo crictl pull gcr.io/cloudcomputingunsa/coarlumini-backend:latest
```

**Solución:**
```bash
# Configurar gcloud auth
sudo gcloud auth configure-docker gcr.io --quiet

# Reiniciar K3s
sudo systemctl restart k3s
```

---

## 📊 DIFERENCIAS CLAVE: ANTES vs DESPUÉS

| Aspecto | ANTES ❌ | DESPUÉS ✅ |
|---------|----------|------------|
| **Runtime** | Docker | Containerd (crictl) |
| **Pull de imágenes** | `docker pull` | `crictl pull` |
| **Autenticación** | Manual/incompleta | ImagePullSecret automático |
| **Tag de frontend** | `latestst` (typo) | `latest` (correcto) |
| **nginx-config** | No se aplicaba | Se aplica antes del frontend |
| **imagePullSecrets** | No presente | Presente en todos los deployments |
| **Validación** | Manual | Script automático |
| **Service Account** | Sin permisos GCR | Con `storage.objectViewer` |

---

## 🔑 CONCEPTOS CLAVE

### ¿Por qué Containerd y no Docker?

K3s es una distribución ligera de Kubernetes que usa **containerd** directamente como runtime de contenedores, sin la capa de Docker. Esto lo hace más eficiente en recursos.

**Herramientas:**
- `crictl` - Cliente CLI para containerd (equivalente a `docker`)
- `ctr` - Cliente de bajo nivel de containerd

### ¿Qué es un ImagePullSecret?

Es un Secret de Kubernetes que contiene las credenciales para autenticarse con registros privados de imágenes (como GCR).

**Estructura:**
```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: gcr-json-key
  namespace: coarlumini
data:
  .dockerconfigjson: <base64-encoded-credentials>
```

**Uso en Deployment:**
```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: gcr-json-key
```

### ¿Por qué la Service Account necesita permisos?

La Service Account que usan las instancias de GCE necesita permisos para:
- **Leer de GCR:** `roles/storage.objectViewer`
- **Autenticarse con GCR:** Credenciales en formato JSON

---

## 📚 REFERENCIAS

- [K3s Documentation](https://docs.k3s.io/)
- [Kubernetes ImagePullSecrets](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)
- [Google Container Registry Authentication](https://cloud.google.com/container-registry/docs/advanced-authentication)
- [Containerd Documentation](https://containerd.io/)
- [crictl Command Reference](https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md)

---

## 📝 NOTAS FINALES

1. **Siempre ejecuta `pre-deploy-validation.sh` antes de un deployment completo**
2. **Los scripts de corrección (`fix-*.sh`) son idempotentes - puedes ejecutarlos múltiples veces**
3. **K3s usa containerd - usa `crictl`, no `docker`**
4. **ImagePullSecret es esencial para GCR privado**
5. **El orden de aplicación de manifiestos importa (nginx-config antes que frontend)**

---

**Última actualización:** 2025-11-06  
**Versión:** 2.0  
**Autor:** Sistema de Deployment Automatizado K3s+GCR