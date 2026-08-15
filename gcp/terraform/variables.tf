# ============================================================
# Input variables
# ============================================================

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Deployment region"
  type        = string
  default     = "asia-northeast1"
}

variable "bucket_name" {
  description = "Cloud Storage bucket for photos. Defaults to <project_id>-photos."
  type        = string
  default     = ""
}

variable "require_email" {
  description = "Require email for signup"
  type        = bool
  default     = true
}

variable "require_phone" {
  description = "Require phone number for signup"
  type        = bool
  default     = false
}

variable "enable_share_url" {
  description = "Enable upload URL sharing feature"
  type        = bool
  default     = true
}

variable "enable_share_download_url" {
  description = "Enable download URL sharing feature"
  type        = bool
  default     = true
}

variable "enable_label_sharing" {
  description = "Enable label sharing between users"
  type        = bool
  default     = true
}

variable "app_display_name" {
  description = "Display name shown in the app"
  type        = string
  default     = "Daily Cloud Photo Backend"
}

# ── Derived locals ──
locals {
  photos_bucket = var.bucket_name != "" ? var.bucket_name : "${var.project_id}-photos"
  api_function_name     = "daily-cloud-photo-api"
  trigger_function_name = "daily-cloud-photo-storage-trigger"
}
