# Phase 2: Cloud Monitoring alert — node CPU > 80%
resource "google_monitoring_alert_policy" "node_cpu" {
  display_name = "${var.cluster_name} Node CPU High"
  combiner     = "OR"

  conditions {
    display_name = "Node CPU utilization > 80%"
    condition_threshold {
      filter          = "resource.type = \"k8s_node\" AND metric.type = \"kubernetes.io/node/cpu/allocatable_utilization\""
      duration        = "120s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = []
  enabled               = true
}
