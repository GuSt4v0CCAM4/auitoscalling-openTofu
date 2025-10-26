output "load_balancer_ip" {
  description = "IP del Load Balancer para acceder  a la demo"
  value = google_compute_global_forwarding_rule.web_forwarding.ip_address
}

output "autoscaler_status" {
  description = "Enlace al autoscaler en Google Cloud Console"
  value = "https://console.cloud.google.com/compute/autoscalers?project=${var.project_id}"
}

output "instance_group_url" {
  description = "Enlace al instance group manager"
  value = "https://console.cloud.google.com/compute/instanceGroups?project=${var.project_id}"
}
