# Plans the small trial against a mocked google provider, so it needs no credentials and
# creates nothing. Run with: terraform init -backend=false && terraform test

mock_provider "google" {
  override_during = plan

  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      email = "sandbox-controller@my-trial-project.iam.gserviceaccount.com"
      name  = "projects/my-trial-project/serviceAccounts/sandbox-controller@my-trial-project.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id      = "my-trial-project"
  operator_member = "user:you@example.com"
}

run "small_trial_plan" {
  command = plan

  assert {
    condition     = google_container_cluster.sandboxes.location == "us-central1-a"
    error_message = "The cluster must be zonal to get the free tier credit."
  }

  assert {
    condition     = google_container_cluster.sandboxes.deletion_protection
    error_message = "Deletion protection must default to true."
  }

  assert {
    condition = (
      google_container_node_pool.sandbox_system.node_config[0].machine_type == "e2-standard-2" &&
      google_container_node_pool.sandboxes.node_config[0].machine_type == "e2-highmem-4"
    )
    error_message = "Unexpected machine types."
  }

  # e2-standard-2 has 2 vCPU and e2-highmem-4 has 4. The free trial caps the project at 8.
  assert {
    condition = (
      google_container_node_pool.sandbox_system.autoscaling[0].total_max_node_count * 2 +
      google_container_node_pool.sandboxes.autoscaling[0].total_max_node_count * 4
    ) <= 8
    error_message = "At max autoscale the cluster would need more than 8 vCPU."
  }

  assert {
    condition = alltrue([
      for pool in [google_container_node_pool.sandbox_system, google_container_node_pool.sandboxes] :
      pool.upgrade_settings[0].max_surge == 0
    ])
    error_message = "A surge node during upgrades would go over the vCPU quota."
  }

  assert {
    condition     = strcontains(output.manifests, "npm ci --ignore-scripts") && !strcontains(output.manifests, "npm install")
    error_message = "The sweeper must install from its lockfile."
  }

  assert {
    condition     = strcontains(output.manifests, "replicas: 0\n  selector:\n    matchLabels:\n      app: sandbox-headroom")
    error_message = "Headroom must default to zero replicas."
  }
}

run "zone_outside_region_is_rejected" {
  command = plan

  variables {
    zone = "europe-west1-b"
  }

  expect_failures = [var.zone]
}
