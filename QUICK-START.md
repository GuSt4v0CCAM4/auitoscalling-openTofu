# 🚀 QUICK START - Deployment Corregido

Esta guía rápida te ayudará a desplegar Coarlumini en K3s + GCP con todas las correcciones aplicadas.

---

## ✅ PRE-REQUISITOS

```bash
# Herramientas necesarias
- gcloud CLI instalado
- Docker instalado (para build local)
- Terraform/Tofu instalado
- Cuenta de GCP con permisos de administrador

# Variables de entorno
export PROJECT_ID=cloudcomputingunsa
export ZONE=us-central1-a
export REGION=us-central1
```

---

## 🎯 DEPLOYMENT EN 3 PASOS

### **Paso 1: Validación Pre-Deployment**

```bash
cd autoscaling-demo

# Ejecutar validación automática
./scripts/pre-deploy-validation.sh
```

**¿Qué valida?**
- ✅ Manifiestos de Kubernetes existen
- ✅ ImagePullSecrets configurados
- ✅ Tags de imágenes correctos
- ✅ Imágenes en GCR disponibles
- ✅ Service Account con permisos
- ✅ Scripts usando crictl (containerd)

---

### **Paso 2: Deployment Completo**

```bash
export PROJECT_ID=cloudcomputingunsa

# Deployment automático con todas las correcciones
./scripts/full-deploy.sh
```

**Tiempo estimado:** 10-15 minutos

**¿Qué hace?**
1. ✅ Valida herramientas (gcloud, docker, terraform)
2. ✅ Verifica/construye imágenes en GCR
3. ✅ Valida y actualiza manifiestos
4. ✅ Despliega infraestructura con Terraform/Tofu
5. ✅ Espera que K3s esté listo
6. ✅ Crea ImagePullSecret automáticamente
7. ✅ Descarga imágenes con crictl (containerd)
8. ✅ Despliega aplicación Coarlumini
9. ✅ Muestra URLs de acceso

---

### **Paso 3: Verificación**

```bash
# Verificar estado de los pods
gcloud compute ssh k3s-master-server --zone=$ZONE --command="
  sudo kubectl get pods -n coarlumini
"
```

**Salida esperada:**
```
NAME                                   READY   STATUS    RESTARTS   AGE
coarlumini-backend-xxx                 1/1     Running   0          2m
coarlumini-database-xxx                1/1     Running   0          3m
coarlumini-frontend-xxx                1/1     Running   0          2m
```

---

## 🔧 SI ALGO SALE MAL

### **Pods en ImagePullBackOff**

```bash
# Script de corrección automática
./scripts/fix-final.sh
```

**Esto corrige:**
- ❌ Falta de ImagePullSecret
- ❌ Permisos incorrectos de Service Account
- ❌ Tags de imágenes incorrectos

---

### **Error: "configmap nginx-config not found"**

```bash
# Script específico para frontend
./scripts/fix-frontend.sh
```

---

### **Empezar desde Cero**

```bash
# Limpia todo y redespliega
./scripts/clean-redeploy.sh
```

**⚠️ ADVERTENCIA:** Esto destruirá toda la infraestructura actual.

---

## 📊 COMANDOS ÚTILES

### **Ver Estado del Cluster**

```bash
# SSH al master
gcloud compute ssh k3s-master-server --zone=$ZONE

# Ver nodos
sudo kubectl get nodes

# Ver pods
sudo kubectl get pods -n coarlumini -o wide

# Ver servicios
sudo kubectl get svc -n coarlumini
```

### **Ver Logs de un Pod**

```bash
# Obtener nombre del pod
sudo kubectl get pods -n coarlumini

# Ver logs
sudo kubectl logs <pod-name> -n coarlumini

# Seguir logs en tiempo real
sudo kubectl logs -f <pod-name> -n coarlumini
```

### **Describir un Pod con Problemas**

```bash
sudo kubectl describe pod <pod-name> -n coarlumini
```

### **Verificar ImagePullSecret**

```bash
sudo kubectl get secret gcr-json-key -n coarlumini
```

### **Ver Imágenes en Containerd (K3s)**

```bash
# En el master o workers
sudo crictl images | grep coarlumini
```

---

## 🎨 ACCESO A LA APLICACIÓN

Después del deployment, obtendrás:

```
📍 ACCESO A LA APLICACIÓN:
  
  🌐 URL del Frontend:
     http://XX.XX.XX.XX:30080
  
  🌐 Load Balancer (Global):
     http://YY.YY.YY.YY
```

**Accede desde tu navegador a cualquiera de estas URLs.**

---

## 🐛 TROUBLESHOOTING RÁPIDO

| Problema | Comando de Diagnóstico | Solución |
|----------|------------------------|----------|
| Pods en `ImagePullBackOff` | `kubectl describe pod <name> -n coarlumini` | `./scripts/fix-final.sh` |
| Nodos en `NotReady` | `kubectl get nodes` | Esperar 5 min o recrear workers |
| ConfigMap no encontrado | `kubectl get cm -n coarlumini` | `./scripts/fix-frontend.sh` |
| Error 502 Bad Gateway | `kubectl get pods -n coarlumini` | Verificar que pods estén Running |
| Imagen no encontrada | `crictl images \| grep coarlumini` | `crictl pull gcr.io/...` |

---

## ⚙️ CONFIGURACIÓN IMPORTANTE

### **K3s usa Containerd, NO Docker**

```bash
# ❌ INCORRECTO
docker pull gcr.io/...

# ✅ CORRECTO
sudo crictl pull gcr.io/...
```

### **ImagePullSecret es Obligatorio para GCR**

Todos los deployments tienen:
```yaml
spec:
  imagePullSecrets:
    - name: gcr-json-key
```

### **Tags de Imágenes Deben ser Correctos**

```bash
# ✅ CORRECTO
gcr.io/cloudcomputingunsa/coarlumini-frontend:latest

# ❌ INCORRECTO (typo común)
gcr.io/cloudcomputingunsa/coarlumini-frontend:latestst
```

---

## 📋 CHECKLIST POST-DEPLOYMENT

- [ ] Todos los pods están en estado `Running`
- [ ] ImagePullSecret `gcr-json-key` existe en namespace `coarlumini`
- [ ] Imágenes visibles con `sudo crictl images | grep coarlumini`
- [ ] Frontend accesible desde navegador
- [ ] Backend responde (verificar logs)
- [ ] Database está `Ready` (puede tardar ~30s)

---

## 🔄 FLUJO DE DEPLOYMENT

```
1. pre-deploy-validation.sh
   ↓
2. full-deploy.sh
   ↓ (construye infraestructura)
3. k3s-server-init.sh
   ↓ (crea ImagePullSecret)
   ↓ (descarga imágenes con crictl)
4. k3s-agent-init.sh
   ↓ (workers se unen al cluster)
5. deploy-coarlumini.sh
   ↓ (aplica manifiestos K8s)
6. ✅ Aplicación Running
```

---

## 💡 TIPS IMPORTANTES

1. **Siempre ejecuta `pre-deploy-validation.sh` primero**
2. **Espera 5-10 minutos después del deployment para que todo se estabilice**
3. **Los scripts de fix son idempotentes - puedes ejecutarlos múltiples veces**
4. **K3s reinicia los pods automáticamente si fallan**
5. **El autoscaler puede crear más workers según la carga**

---

## 📚 MÁS INFORMACIÓN

- **Guía completa de correcciones:** `DEPLOYMENT-FIXES.md`
- **Troubleshooting detallado:** `SOLUCION-PROBLEMAS.md`
- **Cambios recientes:** `CHANGES.md`

---

## 🎯 SIGUIENTE PASO

Después de desplegar exitosamente:

```bash
# Monitorear los pods
watch -n 2 'kubectl get pods -n coarlumini'

# Acceder a la aplicación
# URL mostrada al final del deployment
```

---

**¡Listo! Tu aplicación Coarlumini debería estar funcionando en K3s + GCP con todas las correcciones aplicadas.**

---

**Última actualización:** 2025-11-06  
**Versión:** 2.0  
**Estado:** ✅ Todas las correcciones aplicadas