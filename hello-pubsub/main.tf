data "google_project" "project" {
  project_id = var.project_id
}

resource "google_project_service" "all" {
  for_each           = toset(var.gcp_service_list)
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# Handle Permissions
variable "build_roles_list" {
  description = "The list of roles that build needs for"
  type        = list(string)
  default = [
    "roles/run.developer",
    "roles/vpaccess.user",
    "roles/iam.serviceAccountUser",
    "roles/run.admin",
    "roles/secretmanager.secretAccessor",
    "roles/artifactregistry.admin",
  ]
}

# Create artifact repository
resource "google_artifact_registry_repository" "hello-pubsub" {
  provider      = google-beta
  format        = "DOCKER"
  location      = var.region
  project       = var.project_id
  repository_id = "${var.basename}-artifacts"
  depends_on    = [google_project_service.all]
}

# Build docker image and push to artifact repository
resource "null_resource" "cloudbuild_hello_pubsub" {
  provisioner "local-exec" {
    working_dir = path.module
    command     = "gcloud builds submit . --substitutions=_REGION=${var.region},_BASENAME=${var.basename}"
  }

  depends_on = [
    google_artifact_registry_repository.hello-pubsub,
    google_project_service.all
  ]
}

# Create cloud run service
resource "google_cloud_run_v2_service" "frontend" {
  name     = "${var.basename}-frontend"
  location = var.region
  project  = var.project_id

  template {
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.basename}-artifacts/hello"
    }
  }
  depends_on = [
    null_resource.cloudbuild_hello_pubsub,
  ]
}

resource "google_service_account" "sa" {
  project      = var.project_id
  account_id   = "cloud-run-pubsub-invoker"
  display_name = "Cloud Run Pub/Sub Invoker"
}

// Create pubsub topic
resource "google_pubsub_topic" "default" {
  project = var.project_id
  name    = "hello_topic"
}

# Create pubsub subscription
resource "google_pubsub_subscription" "default" {
  project = var.project_id
  name    = "hello-topic-subscription"
  topic   = google_pubsub_topic.default.name

  ack_deadline_seconds = 20

  push_config {
    push_endpoint = google_cloud_run_v2_service.frontend.uri

    oidc_token {
      service_account_email = google_service_account.sa.email
    }

    attributes = {
      x-goog-version = "v1"
    }
  }

  depends_on = [google_cloud_run_v2_service.frontend]
}



resource "google_cloud_run_v2_service_iam_binding" "binding" {
  project  = google_cloud_run_v2_service.frontend.project
  location = google_cloud_run_v2_service.frontend.location
  name     = google_cloud_run_v2_service.frontend.name
  role     = "roles/run.invoker"
  members = [
    "serviceAccount:${google_service_account.sa.email}"
  ]
}

resource "google_project_service_identity" "pubsub_agent" {
  provider = google-beta
  project  = data.google_project.project.project_id
  service  = "pubsub.googleapis.com"
}

resource "google_project_iam_binding" "project_token_creator" {
  project = data.google_project.project.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  members = ["serviceAccount:${google_project_service_identity.pubsub_agent.email}"]
}

