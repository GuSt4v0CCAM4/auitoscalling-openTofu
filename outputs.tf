output "load_balancer_ip" {
  description = "IP del Load Balancer para acceder a la aplicación"
  value       = google_compute_global_forwarding_rule.web_forwarding.ip_address
}

output "k3s_server_ip" {
  description = "IP pública del servidor K3s (master)"
  value       = google_compute_instance.k3s_server.network_interface[0].access_config[0].nat_ip
}

output "k3s_server_internal_ip" {
  description = "IP interna del servidor K3s"
  value       = google_compute_instance.k3s_server.network_interface[0].network_ip
}

output "autoscaler_status" {
  description = "Enlace al autoscaler en Google Cloud Console"
  value       = "https://console.cloud.google.com/compute/autoscalers?project=${var.project_id}"
}

output "instance_group_url" {
  description = "Enlace al instance group manager"
  value       = "https://console.cloud.google.com/compute/instanceGroups?project=${var.project_id}"
}

output "k3s_token" {
  description = "Token para unir nodos al cluster K3s"
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "db_password" {
  description = "Password de la base de datos MySQL"
  value       = random_password.db_password.result
  sensitive   = true
}

output "app_key" {
  description = "Laravel application key"
  value       = "base64:${base64encode(random_id.app_key.hex)}"
  sensitive   = true
}

output "access_urls" {
  description = "URLs para acceder a la aplicación Coarlumini"
  value = {
    load_balancer = "http://${google_compute_global_forwarding_rule.web_forwarding.ip_address}"
    direct_server = "http://${google_compute_instance.k3s_server.network_interface[0].access_config[0].nat_ip}:30080"
  }
}

output "ssh_commands" {
  description = "Comandos SSH para conectarse a los recursos"
  value = {
    k3s_server = "gcloud compute ssh ${google_compute_instance.k3s_server.name} --zone=${var.region}-a --project=${var.project_id}"
  }
}

output "kubectl_config_command" {
  description = "Comando para obtener kubeconfig y configurar kubectl local"
  value       = "gcloud compute ssh ${google_compute_instance.k3s_server.name} --zone=${var.region}-a --project=${var.project_id} --command='sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1/${google_compute_instance.k3s_server.network_interface[0].access_config[0].nat_ip}/g' > kubeconfig.yaml && export KUBECONFIG=./kubeconfig.yaml"
}

output "manifests_bucket" {
  description = "GCS bucket conteniendo los manifiestos de Kubernetes"
  value       = google_storage_bucket.k8s_manifests.name
}

output "deployment_summary" {
  description = "Resumen del deployment"
  value = {
    cluster_name    = "K3s Coarlumini Cluster"
    master_node     = google_compute_instance.k3s_server.name
    worker_group    = google_compute_instance_group_manager.web_group.name
    min_workers     = var.min_replicas
    max_workers     = var.max_replicas
    load_balancer   = google_compute_global_forwarding_rule.web_forwarding.name
    application     = "Coarlumini (Laravel + Vue.js + MySQL)"
  }
}
