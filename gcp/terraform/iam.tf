# ============================================================
# IAM
# ============================================================
#
# Gen2 Cloud Functions run on Cloud Run using the default compute
# service account. We grant that account the minimum roles required for:
#   - generating signed URLs (signBlob → Service Account Token Creator)
#   - receiving Eventarc events (storage finalize trigger)
#   - reading/writing photos and thumbnails (storage.objectAdmin on bucket)
#   - reading/writing metadata (Firestore user)
#
# The Cloud Storage service agent needs pubsub.publisher so it can publish
# object-finalize events to Eventarc.

locals {
  compute_sa = "${data.google_project.current.number}-compute@developer.gserviceaccount.com"
  gcs_agent  = "service-${data.google_project.current.number}@gs-project-accounts.iam.gserviceaccount.com"
}

# ── Runtime service account (compute default) ──

# signBlob for generating V4 signed URLs
resource "google_project_iam_member" "function_sa_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${local.compute_sa}"

  depends_on = [google_project_service.enabled]
}

# Receive Eventarc events
resource "google_project_iam_member" "eventarc_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${local.compute_sa}"

  depends_on = [google_project_service.enabled]
}

# Invoke the trigger function via Run
resource "google_project_iam_member" "run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${local.compute_sa}"

  depends_on = [google_project_service.enabled]
}

# Read/write objects in the photos bucket (photos + thumbnails)
resource "google_storage_bucket_iam_member" "function_photos_admin" {
  bucket = google_storage_bucket.photos.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.compute_sa}"
}

# Firestore access for metadata
resource "google_project_iam_member" "function_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${local.compute_sa}"

  depends_on = [google_project_service.enabled]
}

# ── Cloud Storage service agent ──

# Allow GCS to publish object events to Eventarc/Pub-Sub
resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.gcs_agent}"

  depends_on = [google_project_service.enabled]
}
