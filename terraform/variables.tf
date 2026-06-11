variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP Zone (zonal cluster = free control plane)"
  type        = string
  default     = "us-central1-f"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "gke-private-demo"
}

variable "node_count" {
  description = "Initial node count"
  type        = number
  default     = 1
}

variable "github_repo" {
  description = "GitHub repository in org/repo format"
  type        = string
}

variable "grafana_domain" {
  description = "Grafana dashboard domain"
  type        = string
  default     = "gcp-gke.techcloudup.com"
}
