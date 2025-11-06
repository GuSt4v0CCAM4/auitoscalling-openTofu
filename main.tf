terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ============================================
# RANDOM GENERATORS FOR SECRETS
# ============================================

resource "random_password" "k3s_token" {
  length  = 64
  special = false
}

resource "random_password" "db_password" {
  length  = 24
  special = true
}

resource "random_id" "app_key" {
  byte_length = 32
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# ============================================
# NETWORK (Configuración original mantenida)
# ============================================

resource "google_compute_network" "autoscale_network" {
  name                    = "autoscale-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "autoscale_subnet" {
  name          = "autoscale-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.autoscale_network.id
}

# ============================================
# FIREWALL RULES (Ampliado para K3s)
# ============================================

resource "google_compute_firewall" "web" {
  name    = "web-firewall"
  network = google_compute_network.autoscale_network.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "22", "6443", "30000-32767"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server", "k3s-server", "k3s-agent"]
}

resource "google_compute_firewall" "k3s_internal" {
  name    = "k3s-internal-firewall"
  network = google_compute_network.autoscale_network.name

  allow {
    protocol = "tcp"
    ports    = ["6443", "10250", "2379-2380"]
  }

  allow {
    protocol = "udp"
    ports    = ["8472", "51820", "51821"]
  }

  source_ranges = ["10.0.1.0/24"]
  target_tags   = ["k3s-server", "k3s-agent"]
}

# ============================================
# SERVICE ACCOUNT FOR K3S INSTANCES
# ============================================

resource "google_service_account" "k3s_sa" {
  account_id   = "k3s-cluster-sa"
  display_name = "K3s Cluster Service Account"
}

resource "google_project_iam_member" "k3s_sa_storage" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.k3s_sa.email}"
}

resource "google_project_iam_member" "k3s_sa_gcr" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.k3s_sa.email}"
}

resource "google_project_iam_member" "k3s_sa_artifact_registry" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.k3s_sa.email}"
}

# ============================================
# CLOUD STORAGE FOR K8S MANIFESTS
# ============================================

resource "google_storage_bucket" "k8s_manifests" {
  name          = "${var.project_id}-k8s-${random_id.bucket_suffix.hex}"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true
}

# Upload coarlumini manifests to GCS
resource "google_storage_bucket_object" "k8s_manifests" {
  for_each = fileset("${path.module}/../coarlumini/k8s", "*.yaml")

  name   = each.value
  bucket = google_storage_bucket.k8s_manifests.name
  source = "${path.module}/../coarlumini/k8s/${each.value}"
}

# ============================================
# K3S SERVER (MASTER NODE) - FIXED INSTANCE
# ============================================

resource "google_compute_instance" "k3s_server" {
  name         = "k3s-master-server"
  machine_type = var.k3s_server_machine_type
  zone         = "${var.region}-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = google_compute_network.autoscale_network.name
    subnetwork = google_compute_subnetwork.autoscale_subnet.name
    access_config {
      # Ephemeral public IP
    }
  }

  metadata = {
    enable-oslogin = "TRUE"
    k3s-token      = random_password.k3s_token.result
    db-password    = random_password.db_password.result
    app-key        = "base64:${base64encode(random_id.app_key.hex)}"
    project-id     = var.project_id
    bucket-name    = google_storage_bucket.k8s_manifests.name
  }

  metadata_startup_script = file("${path.module}/scripts/k3s-server-init.sh")

  tags = ["k3s-server", "http-server"]

  service_account {
    email  = google_service_account.k3s_sa.email
    scopes = ["cloud-platform"]
  }

  depends_on = [
    google_storage_bucket_object.k8s_manifests
  ]
}

# ============================================
# HEALTH CHECK (Configuración original)
# ============================================

resource "google_compute_health_check" "autohealing" {
  name                = "autohealing-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 80
    request_path = "/"
  }
}

# ============================================
# INSTANCE TEMPLATE (Modificado para K3s agents)
# ============================================

resource "google_compute_instance_template" "web_template" {
  name_prefix  = "k3s-agent-template-"
  machine_type = var.agent_machine_type

  disk {
    source_image = "ubuntu-os-cloud/ubuntu-2204-lts"
    boot         = true
    disk_size_gb = 30
  }

  network_interface {
    network    = google_compute_network.autoscale_network.name
    subnetwork = google_compute_subnetwork.autoscale_subnet.name
    access_config {} # IP pública
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  # Script para instalar K3s agent y nginx para health checks
  metadata_startup_script = templatefile("${path.module}/scripts/k3s-agent-init.sh", {
    k3s_token  = random_password.k3s_token.result
    server_ip  = google_compute_instance.k3s_server.network_interface[0].network_ip
    project_id = var.project_id
  })

  tags = ["http-server", "k3s-agent"]

  service_account {
    email  = google_service_account.k3s_sa.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_compute_instance.k3s_server]
}

# ============================================
# AUTOSCALER (Configuración mejorada)
# ============================================

resource "google_compute_autoscaler" "web_autoscaler" {
  name   = "web-autoscaler"
  zone   = "${var.region}-a"
  target = google_compute_instance_group_manager.web_group.id

  autoscaling_policy {
    max_replicas    = var.max_replicas
    min_replicas    = var.min_replicas
    cooldown_period = 60

    cpu_utilization {
      target = var.cpu_target
    }

    load_balancing_utilization {
      target = 0.6
    }
  }
}

# ============================================
# INSTANCE GROUP MANAGER
# ============================================

resource "google_compute_instance_group_manager" "web_group" {
  name               = "web-group-manager"
  base_instance_name = "k3s-agent"
  zone               = "${var.region}-a"

  version {
    instance_template = google_compute_instance_template.web_template.id
    name              = "primary"
  }

  named_port {
    name = "http"
    port = 80
  }

  target_size = var.min_replicas

  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.id
    initial_delay_sec = 300
  }

  depends_on = [google_compute_instance.k3s_server]
}

# ============================================
# LOAD BALANCER (Configuración original mantenida)
# ============================================

resource "google_compute_backend_service" "web_backend" {
  name          = "web-backend-service"
  port_name     = "http"
  protocol      = "HTTP"
  timeout_sec   = 30
  health_checks = [google_compute_health_check.autohealing.id]

  backend {
    group           = google_compute_instance_group_manager.web_group.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
    max_utilization = 0.8
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "web_url_map" {
  name            = "web-url-map"
  default_service = google_compute_backend_service.web_backend.id
}

resource "google_compute_target_http_proxy" "web_proxy" {
  name    = "web-proxy"
  url_map = google_compute_url_map.web_url_map.id
}

resource "google_compute_global_forwarding_rule" "web_forwarding" {
  name       = "web-forwarding-rule"
  target     = google_compute_target_http_proxy.web_proxy.id
  port_range = "80"
}

# ============================================
# NULL RESOURCE PARA DEPLOYMENT AUTOMÁTICO
# ============================================

resource "null_resource" "deploy_coarlumini" {
  count = var.enable_auto_deploy ? 1 : 0

  # Trigger cuando cambian las instancias o manifiestos
  triggers = {
    server_id        = google_compute_instance.k3s_server.id
    instance_group   = google_compute_instance_group_manager.web_group.id
    manifests_bucket = google_storage_bucket.k8s_manifests.name
  }

  # Esperar a que el servidor K3s esté listo
  provisioner "local-exec" {
    command = "echo '⏳ Esperando ${var.deploy_wait_time} segundos para que K3s server esté listo...' && sleep ${var.deploy_wait_time}"
  }

  # Build y push de imágenes Docker a GCR
  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/build-and-push.sh"
    working_dir = path.module
    environment = {
      PROJECT_ID = var.project_id
    }
    on_failure = continue
  }

  # Deploy de la aplicación Coarlumini
  provisioner "local-exec" {
    command     = "bash ${path.module}/scripts/deploy-to-k3s.sh"
    working_dir = path.module
    environment = {
      PROJECT_ID      = var.project_id
      K3S_SERVER_NAME = google_compute_instance.k3s_server.name
      ZONE            = "${var.region}-a"
    }
    on_failure = continue
  }

  depends_on = [
    google_compute_instance.k3s_server,
    google_compute_instance_group_manager.web_group,
    google_storage_bucket_object.k8s_manifests
  ]
}
