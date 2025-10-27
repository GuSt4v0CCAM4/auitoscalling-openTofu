terraform {
    required_providers {
      google = {
        source = "hashicorp/google"
        version = "~> 5.0"
      }
    }
}
provider "google" {
  project = var.project_id
  region = var.region
}

#network
resource "google_compute_network" "autoscale_network" {
  name = "autoscale-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "autoscale_subnet" {
  name = "autoscale-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region = var.region
  network = google_compute_network.autoscale_network.id
}

#Firewall
resource "google_compute_firewall" "web" {
  name = "web-firewall"
  network = google_compute_network.autoscale_network.name

  allow {
    protocol = "tcp"
    ports = ["80", "22"]
  }
  source_ranges = ["0.0.0.0/0"]
}

#Chequeo del health
resource "google_compute_health_check" "autohealing" {
  name               = "autohealing-health-check"
  check_interval_sec = 5
  timeout_sec        = 5
  healthy_threshold  = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 80
    request_path = "/"
  }
}


#Instancias template
resource "google_compute_instance_template" "web_template" {
  name_prefix  = "web-template-"
  machine_type = "e2-micro"

  disk {
    source_image = "ubuntu-os-cloud/ubuntu-2204-lts"
    boot         = true
  }

  network_interface {
    network    = google_compute_network.autoscale_network.name
    subnetwork = google_compute_subnetwork.autoscale_subnet.name
    access_config {} # IP pública
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  # Script CORREGIDO - usando \$ para variables shell
  metadata_startup_script = <<-EOF
  #!/bin/bash
  apt-get update -y
  apt-get install -y nginx stress-ng curl

  # Configurar nginx
  systemctl enable nginx
  systemctl start nginx

  # Página web inicial
  mkdir -p /var/www/html
  cat <<'EOLA' > /var/www/html/index.html
  <!DOCTYPE html>
  <html>
  <head>
    <title>Autoscaling Demo - GCP</title>
    <style>
      body { font-family: Arial, sans-serif; margin: 40px; }
      .info { background: #f0f0f0; padding: 20px; border-radius: 5px; }
      .load { color: red; font-weight: bold; }
    </style>
  </head>
  <body>
    <h1>Autoscaling Demo - GCP</h1>
    <div class="info">
      <h2>Instance: $(hostname)</h2>
      <p><strong>Zone:</strong> $(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $4}')</p>
      <p><strong>Internal IP:</strong> $(hostname -I | awk '{print $1}')</p>
      <p><strong>CPU Load:</strong> <span class="load" id="load">0%</span></p>
      <p><strong>Uptime:</strong> <span id="uptime">0s</span></p>
    </div>
    <hr>
    <h3>Metricas de Autoscaling</h3>
    <p>Esta demo genera carga automática cada 3 minutos</p>
    <p>Las instancias se escalan cuando CPU > 60%</p>
  </body>
  </html>
  EOLA

  # Script de carga periódica
  cat <<'EOLB' > /usr/local/bin/auto-load.sh
  #!/bin/bash
  echo "$(date): Generando carga de CPU por 60 segundos..."
  stress-ng --cpu 2 --timeout 60
  echo "$(date): Carga completada. Script finalizado."
  EOLB
  chmod +x /usr/local/bin/auto-load.sh

  # Script de actualización de métricas
  cat <<'EOLC' > /usr/local/bin/update-metrics.sh
  #!/bin/bash
  while true; do
    CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
    UPTIME=$(uptime -p)
    sed -i "s/id=\"load\">[^<]*</id=\"load\">$${CPU_LOAD}%</" /var/www/html/index.html
    sed -i "s/id=\"uptime\">[^<]*</id=\"uptime\">$${UPTIME}</" /var/www/html/index.html
    sleep 5
  done
  EOLC
  chmod +x /usr/local/bin/update-metrics.sh

  # Ejecutar ambos scripts en segundo plano
  nohup /usr/local/bin/auto-load.sh > /var/log/auto-load.log 2>&1 &
  nohup /usr/local/bin/update-metrics.sh > /var/log/metrics.log 2>&1 &
  EOF

  tags = ["http-server"]

  lifecycle {
    create_before_destroy = true
  }
}

#configuración  del autoescalamiento
resource "google_compute_autoscaler" "web_autoscaler" {
  name = "web-autoscaler"
  zone = "${var.region}-a"
  target = google_compute_instance_group_manager.web_group.id

  autoscaling_policy {
    max_replicas = 5
    min_replicas = 2
    cooldown_period = 60

    cpu_utilization {
      target = 0.6 #&0% del CPU,  cunado se supere este se autoescalara
    }

    # Agregar escala basada en carga
       load_balancing_utilization {
         target = 0.6
       }
  }
}

#Instance Group Manager
resource "google_compute_instance_group_manager" "web_group" {
  name = "web-group-manager"
  base_instance_name = "web-instance"
  zone = "${var.region}-a"

  version {
    instance_template = google_compute_instance_template.web_template.id
    name = "primary"
  }

  named_port {
    name = "http"
    port = 80
  }

  target_size = 2

  auto_healing_policies {
    health_check = google_compute_health_check.autohealing.id
    initial_delay_sec = 300
  }
}

#Load Balancer
resource "google_compute_backend_service" "web_backend" {
  name        = "web-backend-service"
  port_name   = "http"
  protocol    = "HTTP"
  timeout_sec = 30

  backend {
    group           = google_compute_instance_group_manager.web_group.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
    max_utilization = 0.8
  }

  health_checks = [google_compute_health_check.autohealing.id]

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}


resource "google_compute_url_map" "web_url_map" {
  name = "web-url-map"
  default_service = google_compute_backend_service.web_backend.id
}

resource "google_compute_target_http_proxy" "web_proxy" {
  name = "web-proxy"
  url_map = google_compute_url_map.web_url_map.id
}

resource "google_compute_global_forwarding_rule" "web_forwarding" {
  name = "web-forwarding-rule"
  target = google_compute_target_http_proxy.web_proxy.id
  port_range = "80"
}
