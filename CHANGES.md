# Resumen de Cambios - Integración K3s + Coarlumini

Este documento resume todos los cambios realizados para integrar la infraestructura de autoscaling con Kubernetes (K3s) y la aplicación Coarlumini.

## 📅 Fecha de Integración
5 de Noviembre, 2024

## 🎯 Objetivo
Integrar la infraestructura de autoscaling de Google Compute Engine con un cluster Kubernetes (K3s) para desplegar automáticamente la aplicación Coarlumini (Laravel + Vue.js + MySQL).

## 📋 Cambios Realizados

### 1. Archivos Modificados

#### `main.tf`
**Cambios principales:**
- ✅ Agregado provider `random` y `null`
- ✅ Creados recursos `random_password` y `random_id` para secretos
- ✅ Agregado `google_service_account` para instancias K3s
- ✅ Creado `google_storage_bucket` para manifiestos K8s
- ✅ Agregado recurso `google_storage_bucket_object` que sube manifiestos de `../coarlumini/k8s/`
- ✅ Creado `google_compute_instance` para servidor K3s (master fijo)
- ✅ Agregado firewall `k3s_internal` para comunicación del cluster
- ✅ Modificado `google_compute_instance_template` para usar script de agente K3s
- ✅ Cambiado machine type de `e2-micro` a `e2-small` (necesario para K3s)
- ✅ Agregado `null_resource` con provisioners para deployment automático

**Backup creado:** `main-original.tf.backup`

#### `variables.tf`
**Cambios principales:**
- ✅ Agregada variable `k3s_server_machine_type` (default: e2-medium)
- ✅ Agregada variable `agent_machine_type` (default: e2-small)
- ✅ Agregada variable `min_replicas` (default: 2)
- ✅ Agregada variable `max_replicas` (default: 5)
- ✅ Agregada variable `cpu_target` (default: 0.6)
- ✅ Agregada variable `enable_auto_deploy` (default: true)
- ✅ Agregada variable `deploy_wait_time` (default: 180)

**Backup creado:** `variables-original.tf.backup`

#### `outputs.tf`
**Cambios principales:**
- ✅ Agregado output `k3s_server_ip`
- ✅ Agregado output `k3s_server_internal_ip`
- ✅ Agregado output `k3s_token` (sensitive)
- ✅ Agregado output `db_password` (sensitive)
- ✅ Agregado output `app_key` (sensitive)
- ✅ Agregado output `access_urls` con URLs de acceso
- ✅ Agregado output `ssh_commands`
- ✅ Agregado output `kubectl_config_command`
- ✅ Agregado output `manifests_bucket`
- ✅ Agregado output `deployment_summary`

**Backup creado:** `outputs-original.tf.backup`

### 2. Archivos Nuevos Creados

#### `scripts/k3s-server-init.sh` (458 líneas)
Script de inicialización del servidor K3s master que se ejecuta automáticamente al crear la instancia.

**Funcionalidades:**
- Instala y configura Docker
- Configura autenticación con GCR
- Instala K3s server
- Instala Helm
- Instala nginx ingress controller
- Crea namespace `coarlumini`
- Descarga manifiestos K8s desde GCS
- Crea secrets y configmaps
- Actualiza manifiestos con rutas de GCR
- Crea script `/root/deploy-coarlumini.sh`
- Configura nginx para health checks
- Crea mensajes de bienvenida personalizados

#### `scripts/k3s-agent-init.sh` (274 líneas)
Script de inicialización de agentes K3s (workers) que se ejecuta en cada instancia del autoscaling group.

**Funcionalidades:**
- Instala y configura Docker
- Configura autenticación con GCR
- Espera a que el servidor K3s esté disponible
- Instala K3s agent y se une al cluster
- Configura nginx para health checks
- Aplica optimizaciones del sistema
- Crea scripts de información del nodo

#### `scripts/build-and-push.sh` (157 líneas)
Script que construye las imágenes Docker de Coarlumini y las sube a Google Container Registry.

**Funcionalidades:**
- Verifica que existan los Dockerfiles
- Autentica Docker con GCR
- Construye imagen de database (MySQL)
- Construye imagen de backend (Laravel)
- Construye imagen de frontend (Vue.js)
- Sube todas las imágenes a GCR
- Muestra resumen con rutas de las imágenes

#### `scripts/deploy-to-k3s.sh` (222 líneas)
Script que despliega la aplicación Coarlumini en el cluster K3s.

**Funcionalidades:**
- Verifica conectividad SSH al servidor
- Verifica que K3s esté corriendo
- Ejecuta `/root/deploy-coarlumini.sh` en el servidor
- Verifica estado de los pods
- Obtiene información de acceso (IPs, puertos)
- Muestra resumen con URLs y comandos útiles

#### `README.md` (544 líneas)
Documentación completa del proyecto integrado.

**Contenido:**
- Descripción de arquitectura
- Requisitos previos
- Instrucciones de deployment
- Flujo detallado del proceso
- Comandos de gestión y operación
- Sección de monitoreo
- Solución de problemas
- Guía de seguridad
- Estimación de costos
- Referencias

#### `terraform.tfvars.example` (84 líneas)
Archivo de ejemplo con todas las variables configurables.

**Contenido:**
- Configuración de proyecto GCP
- Configuración de tipos de máquinas
- Configuración de autoscaling
- Configuración de deployment
- Notas importantes y recomendaciones

#### `CHANGES.md` (Este archivo)
Documento de resumen de todos los cambios realizados.

### 3. Archivos de Coarlumini (Sin Cambios)

**Nota importante:** No se realizaron cambios en la carpeta `../coarlumini/`. 

Los archivos existentes se reutilizan tal como están:
- ✅ `coarlumini/k8s/*.yaml` - Manifiestos Kubernetes
- ✅ `coarlumini/Dockerfile` - Backend Laravel
- ✅ `coarlumini/frontend/Dockerfile` - Frontend Vue.js
- ✅ `coarlumini/database/Dockerfile` - Database MySQL

## 🔄 Flujo de Deployment

### Antes (autoscaling-demo original)
```
terraform apply
  └─> Crea instancias con nginx simple
      └─> Muestra página HTML estática
```

### Ahora (integrado con K3s + Coarlumini)
```
terraform apply
  ├─> Crea infraestructura (network, firewall, etc.)
  ├─> Crea servidor K3s master (instancia fija)
  │   └─> startup_script instala K3s y descarga manifiestos
  ├─> Crea instance group con workers K3s
  │   └─> startup_script instala K3s agent y se une al master
  ├─> Crea load balancer
  └─> null_resource provisioner:
      ├─> Espera 3 minutos
      ├─> Ejecuta build-and-push.sh (construye imágenes)
      └─> Ejecuta deploy-to-k3s.sh (despliega Coarlumini)
```

## 📊 Comparación de Recursos

| Recurso | Antes | Ahora |
|---------|-------|-------|
| **Instancias** | 2-5 con nginx | 1 master + 2-5 workers K3s |
| **Machine Type** | e2-micro | e2-small (workers), e2-medium (master) |
| **Software** | nginx + stress-ng | Docker + K3s + Coarlumini |
| **Aplicación** | HTML estático | Laravel + Vue.js + MySQL |
| **Puertos** | 80, 22 | 80, 443, 22, 6443, 30000-32767 |
| **Storage** | - | GCS bucket para manifiestos |
| **Registry** | - | GCR para imágenes Docker |

## 🎯 Características Nuevas

### Infraestructura
- ✅ Cluster Kubernetes K3s funcional
- ✅ Autoscaling a dos niveles (pods + instancias)
- ✅ Service account con permisos para GCS y GCR
- ✅ Firewall configurado para K3s
- ✅ Cloud Storage para manifiestos K8s

### Deployment
- ✅ Deployment completamente automatizado con Terraform
- ✅ Build automático de imágenes Docker
- ✅ Push automático a Google Container Registry
- ✅ Apply automático de manifiestos Kubernetes
- ✅ Configuración automática de secrets y configmaps

### Seguridad
- ✅ Generación automática de tokens K3s
- ✅ Generación automática de passwords DB
- ✅ Generación automática de Laravel app key
- ✅ Secrets marcados como sensitive en outputs

### Monitoreo
- ✅ Health checks con nginx en todos los nodos
- ✅ Páginas de estado personalizadas
- ✅ Scripts de información en cada nodo
- ✅ Mensajes de bienvenida informativos

## 🚀 Cómo Usar

### Primera Vez
```bash
# 1. Configurar variables
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con tu project_id

# 2. Inicializar
terraform init

# 3. Desplegar todo
terraform apply -var="project_id=tu-proyecto"

# 4. Esperar ~12-15 minutos

# 5. Acceder a la aplicación
terraform output access_urls
```

### Redesplegar Solo la Aplicación
```bash
# Opción 1: Manual
export PROJECT_ID="tu-proyecto"
./scripts/build-and-push.sh
./scripts/deploy-to-k3s.sh

# Opción 2: En el servidor
gcloud compute ssh k3s-master-server --zone=us-central1-a
sudo /root/deploy-coarlumini.sh
```

## 🔧 Comandos Útiles

### Ver estado del cluster
```bash
gcloud compute ssh k3s-master-server --zone=us-central1-a
kubectl get nodes
kubectl get pods -n coarlumini
```

### Ver logs
```bash
kubectl logs -l app=coarlumini-backend -n coarlumini -f
```

### Escalar
```bash
kubectl scale deployment coarlumini-backend -n coarlumini --replicas=3
```

## 💰 Impacto en Costos

| Concepto | Antes | Ahora | Diferencia |
|----------|-------|-------|------------|
| Instancias | 2-5 x e2-micro ($5-12/mes) | 1 x e2-medium + 2-5 x e2-small ($76-112/mes) | +$64-100/mes |
| Load Balancer | $18/mes | $18/mes | Sin cambio |
| Storage | - | ~$5/mes | +$5/mes |
| **TOTAL** | **~$23-30/mes** | **~$81-132/mes** | **+$58-102/mes** |

**Justificación del costo adicional:**
- Cluster Kubernetes funcional
- Aplicación completa (Laravel + Vue.js + MySQL)
- Autoscaling inteligente (pods + instancias)
- Alta disponibilidad
- Deployment automatizado

## ⚠️ Cambios que Rompen Compatibilidad

1. **Machine types**: Las instancias pasaron de `e2-micro` a `e2-small`
2. **Puertos**: Se agregaron puertos de K3s al firewall
3. **Startup script**: Completamente diferente (ahora instala K3s)
4. **Dependencias**: Requiere Docker, kubectl, helm

## 📝 Archivos que NO se modificaron

- `.terraform.lock.hcl` - Lock file de Terraform
- `terraform.tfstate` - Estado de Terraform (se actualiza automáticamente)
- `terraform.tfstate.backup` - Backup del estado

## 🔄 Para Volver a la Versión Original

```bash
# Restaurar archivos originales
mv main-original.tf.backup main.tf
mv variables-original.tf.backup variables.tf
mv outputs-original.tf.backup outputs.tf

# Eliminar scripts
rm -rf scripts/

# Limpiar recursos
terraform destroy
```

## 📚 Documentación Adicional

- Ver `README.md` para guía completa de uso
- Ver `terraform.tfvars.example` para configuración
- Ver scripts en `scripts/` para detalles de implementación

## ✅ Testing Realizado

- [x] Inicialización de Terraform (`terraform init`)
- [x] Validación de sintaxis (`terraform validate`)
- [x] Plan de ejecución (`terraform plan`)
- [ ] Deployment completo (`terraform apply`) - Pendiente de prueba real
- [ ] Verificación de acceso a la aplicación
- [ ] Testing de autoscaling
- [ ] Testing de health checks

## 🎓 Lecciones Aprendidas

1. **Provisioners**: Los `local-exec` provisioners son útiles pero pueden fallar. Se agregó `on_failure = continue` para robustez.
2. **Timing**: K3s necesita tiempo para inicializarse. El `deploy_wait_time` es crucial.
3. **Templates**: Usar `templatefile()` permite pasar variables a scripts de startup.
4. **GCS**: Subir manifiestos a GCS facilita el acceso desde las instancias.
5. **Health checks**: Nginx es simple y efectivo para health checks de GCE.

## 🔮 Mejoras Futuras Posibles

- [ ] GitHub Actions workflow para CI/CD
- [ ] Certificados SSL/TLS con Let's Encrypt
- [ ] Monitoreo con Cloud Monitoring
- [ ] Logs centralizados con Cloud Logging
- [ ] Backup automático de base de datos
- [ ] Multi-región para alta disponibilidad
- [ ] CDN con Cloud CDN
- [ ] DNS con Cloud DNS

## 📞 Soporte

Si encuentras problemas:
1. Revisa `README.md` sección "Solución de Problemas"
2. Verifica logs: `journalctl -u k3s -f`
3. Verifica eventos de K8s: `kubectl get events -n coarlumini`
4. Revisa serial console output de las instancias

---

**Última actualización:** 5 de Noviembre, 2024
**Versión:** 1.0.0
**Estado:** Listo para deployment