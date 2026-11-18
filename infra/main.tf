terraform {
  required_version = ">= 1.15"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.1.0"
    }
  }
}

variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}
variable "zone" {
  type        = string
  default     = "us-central1-a"
  description = "Zone for the cluster and its nodes. A zonal cluster qualifies for GKE's free tier credit, which covers the management fee of one zonal or Autopilot cluster per billing account."
  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "The zone must be inside var.region."
  }
}
variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Blocks terraform destroy of the cluster. Set it to false and apply once before you destroy."
}
variable "name_suffix" {
  type        = string
  default     = ""
  description = "Appended to every resource name, such as -staging, so one project can hold more than one deployment."
}
variable "sweeper_enabled" {
  type        = bool
  default     = true
  description = "Run the bundled sweeper, which puts idle sandboxes to sleep once a minute. Turn it off when your backend calls sleepUnused() itself, for example to pass drain."
}
variable "sweeper_idle_seconds" {
  type        = number
  default     = 300
  description = "How long a sandbox goes unused before the sweeper puts it to sleep. Match the client's idleTimeoutMs."
}
variable "sandbox_machine_type" {
  type        = string
  default     = "e2-highmem-4"
  description = "Machine type for sandbox nodes. Newer families such as c4d-highmem-16 need sandbox_node_disk_type = \"hyperdisk-balanced\"."
}
variable "sandbox_node_disk_type" {
  type    = string
  default = "pd-balanced"
}
variable "sandbox_max_pods_per_node" {
  type        = number
  default     = 32
  description = "Pods a sandbox node may hold, system pods included. On GKE 1.37.2 and later a lower value also lowers the node's memory reservation."
}
variable "sandbox_node_disk_gb" {
  type        = number
  default     = 100
  description = "Balanced boot disk per sandbox node. Increase for denser packing and workloads with more scratch data."
}

variable "max_sandbox_nodes" {
  type        = number
  default     = 1
  description = "Autoscaling ceiling for this deployment. Size for your workload and regional quota. With the defaults the cluster peaks at 2 system nodes x 2 vCPU + this x 4 vCPU, so 1 keeps it at the free trial's 8 vCPU."
  validation {
    condition     = var.max_sandbox_nodes >= 1 && floor(var.max_sandbox_nodes) == var.max_sandbox_nodes
    error_message = "Supply a positive whole number of nodes."
  }
}
variable "headroom_replicas" {
  type        = number
  default     = 0
  description = "Placeholder pods that keep one sandbox's worth of capacity free. Each one holds a slot on a small node, so the trial runs without them."
}
variable "operator_member" {
  type        = string
  description = "IAM member allowed to impersonate the example controller, such as user:you@example.com."
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "current" { project_id = var.project_id }

locals {
  sandbox_namespace       = "sandboxes"
  sandbox_service_account = "sandbox"
  sandbox_identity_pool   = "iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog"
}

resource "google_project_service" "apis" {
  for_each           = toset(["compute", "container", "containerfilesystem", "iam", "iamcredentials", "storage"])
  project            = var.project_id
  service            = "${each.value}.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "sandboxes" {
  name                    = "sandboxes${var.name_suffix}"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "sandboxes" {
  name                     = "sandboxes${var.name_suffix}"
  ip_cidr_range            = "10.60.0.0/22"
  network                  = google_compute_network.sandboxes.id
  private_ip_google_access = true
  project                  = var.project_id
  region                   = var.region

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.64.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.61.0.0/22"
  }
}

resource "google_compute_router" "sandboxes" {
  name    = "sandboxes${var.name_suffix}-router"
  network = google_compute_network.sandboxes.id
  project = var.project_id
  region  = var.region
}

resource "google_compute_router_nat" "sandboxes" {
  name                               = "sandboxes${var.name_suffix}-nat"
  nat_ip_allocate_option             = "AUTO_ONLY"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.sandboxes.name
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  enable_dynamic_port_allocation      = true
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = 1024
  max_ports_per_vm                    = 65536

  log_config {
    enable = true
    filter = "ALL"
  }

  subnetwork {
    name                    = google_compute_subnetwork.sandboxes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

resource "google_compute_firewall" "sandboxes_deny_smtp" {
  name               = "sandboxes${var.name_suffix}-deny-smtp"
  network            = google_compute_network.sandboxes.id
  project            = var.project_id
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["sandbox-node"]

  deny {
    protocol = "tcp"
    ports    = ["25", "465", "587"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_service_account" "sandbox_nodes" {
  depends_on   = [google_project_service.apis]
  account_id   = "sandbox-nodes${var.name_suffix}"
  display_name = "Sandbox cluster nodes"
  project      = var.project_id
}

resource "google_project_iam_member" "sandbox_nodes" {
  for_each = toset(["roles/container.defaultNodeServiceAccount", "roles/artifactregistry.reader"])

  member  = "serviceAccount:${google_service_account.sandbox_nodes.email}"
  project = var.project_id
  role    = each.value
}

resource "google_container_cluster" "sandboxes" {
  name                = "sandboxes${var.name_suffix}"
  deletion_protection = var.deletion_protection
  location            = var.zone
  network             = google_compute_network.sandboxes.id
  subnetwork          = google_compute_subnetwork.sandboxes.id
  project             = var.project_id

  initial_node_count       = 1
  remove_default_node_pool = true
  # The default pool exists only while the cluster is created. A small disk keeps it inside the
  # trial's SSD quota.
  node_config {
    service_account = google_service_account.sandbox_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    disk_size_gb    = 50
  }
  # Once the first node pool is removed, GKE reports another pool's settings here. Without this,
  # every later apply would replace the cluster.
  lifecycle {
    ignore_changes = [node_config]
  }

  datapath_provider = "ADVANCED_DATAPATH"

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  default_snat_status {
    disabled = true
  }

  private_cluster_config {
    enable_private_nodes   = true
    master_ipv4_cidr_block = "172.16.0.0/28"
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }

    ip_endpoints_config {
      enabled = false
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    pod_snapshot_config {
      enabled = true
    }
  }

  depends_on = [google_project_service.apis, google_project_iam_member.sandbox_nodes]
}

resource "google_container_node_pool" "sandbox_system" {
  name     = "system"
  cluster  = google_container_cluster.sandboxes.id
  project  = var.project_id
  location = var.zone

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 2
  }

  # Upgrade in place, without a surge node, so the cluster never goes over its vCPU quota.
  upgrade_settings {
    max_surge       = 0
    max_unavailable = 1
  }

  node_config {
    machine_type    = "e2-standard-2"
    disk_size_gb    = 50
    service_account = google_service_account.sandbox_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

resource "google_container_node_pool" "sandboxes" {
  name     = "sandboxes"
  cluster  = google_container_cluster.sandboxes.id
  project  = var.project_id
  location = var.zone

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = var.max_sandbox_nodes
    location_policy      = "ANY"
  }

  upgrade_settings {
    max_surge       = 0
    max_unavailable = 1
  }

  max_pods_per_node = var.sandbox_max_pods_per_node

  node_config {
    machine_type    = var.sandbox_machine_type
    service_account = google_service_account.sandbox_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    tags            = ["sandbox-node"]

    disk_type    = var.sandbox_node_disk_type
    disk_size_gb = var.sandbox_node_disk_gb

    sandbox_config {
      type = "GVISOR"
    }

    gcfs_config {
      enabled = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

resource "google_storage_bucket" "sandbox_snapshots" {
  depends_on                  = [google_project_service.apis]
  force_destroy               = false
  location                    = upper(var.region)
  name                        = "${var.project_id}-sandbox-snapshots${var.name_suffix}"
  project                     = var.project_id
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  hierarchical_namespace {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }
}

# Snapshots are read and written with tokens GKE's node service agent mints for one snapshot's
# path (`tokenSource: federatedP4SA` in the storage config), so no sandbox identity has access to
# the bucket. That agent needs to administer the bucket to mint them.
resource "google_storage_bucket_iam_member" "sandbox_snapshots_node_agent" {
  bucket = google_storage_bucket.sandbox_snapshots.name
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-gkenode.iam.gserviceaccount.com"
  role   = "roles/storage.admin"

  depends_on = [google_container_cluster.sandboxes]
}

resource "google_storage_bucket_iam_member" "sandbox_snapshots_gke" {
  bucket = google_storage_bucket.sandbox_snapshots.name
  member = "serviceAccount:service-${data.google_project.current.number}@container-engine-robot.iam.gserviceaccount.com"
  role   = "roles/storage.objectUser"

  depends_on = [google_container_cluster.sandboxes]
}

resource "google_service_account" "controller" {
  account_id = "sandbox-controller${var.name_suffix}"
  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "controller" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "serviceAccount:${google_service_account.controller.email}"
}

resource "google_service_account_iam_member" "operator" {
  service_account_id = google_service_account.controller.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = var.operator_member
}

output "controller" { value = google_service_account.controller.email }
output "endpoint" {
  value = "https://${google_container_cluster.sandboxes.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}"
}
output "manifests" {
  value = templatefile("${path.module}/resources.yaml.tftpl", {
    bucket            = google_storage_bucket.sandbox_snapshots.name
    controller        = google_service_account.controller.email
    headroom_replicas = var.headroom_replicas
    sweeper_replicas  = var.sweeper_enabled ? 1 : 0
    sweeper_idle_ms   = var.sweeper_idle_seconds * 1000
    # The sweeper installs exactly what this lockfile names, with npm ci.
    sweeper_package_json = indent(4, file("${path.module}/sweeper/package.json"))
    sweeper_package_lock = indent(4, file("${path.module}/sweeper/package-lock.json"))
  })
}
