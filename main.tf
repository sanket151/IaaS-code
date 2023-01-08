provider "google" {
  project = <Project-id-here>
  region  = "us-central1"
}

locals {
  ssh_user         = "ansible"
  private_key_path = "<absolute>/.ssh/ansible_ed25519"
}
data "google_compute_image" "sample_image" {
  family  = "debian-11"
  project = "debian-cloud"
}


# VPC creation
resource "google_compute_network" "net" {
  project                 = <Project-id-here>
  name                    = "my-network"
  auto_create_subnetworks = false
}

# Subnet Creation
resource "google_compute_subnetwork" "subnet" {
  name          = "my-subnetwork"
  project       = <Project-id-here>
  network       = google_compute_network.net.id
  ip_cidr_range = "10.0.0.0/16"
  region        = "us-central1"
}
# Cloud Router Creation
resource "google_compute_router" "router" {
  project = <Project-id-here>
  name    = "my-router"
  region  = google_compute_subnetwork.subnet.region
  network = google_compute_network.net.id
}

resource "google_compute_address" "addr1" {
  project = <Project-id-here>
  name    = "nat-address1"
  region  = google_compute_subnetwork.subnet.region
}

resource "google_compute_address" "addr2" {
  project = <Project-id-here>
  name    = "nat-address2"
  region  = google_compute_subnetwork.subnet.region
}

resource "google_compute_address" "addr3" {
  project = <Project-id-here>
  name    = "nat-address3"
  region  = google_compute_subnetwork.subnet.region
}

# Nat Rules Defining/Creation
resource "google_compute_router_nat" "nat_rules" {
  project = <Project-id-here>
  name    = "my-router-nat"
  router  = google_compute_router.router.name
  region  = google_compute_router.router.region

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = [google_compute_address.addr1.self_link]

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  rules {
    rule_number = 100
    description = "nat rules example"
    match       = "inIpRange(destination.ip, '1.1.0.0/16') || inIpRange(destination.ip, '2.2.0.0/16')"
    action {
      source_nat_active_ips = [google_compute_address.addr2.self_link, google_compute_address.addr3.self_link]
    }
  }

  enable_endpoint_independent_mapping = false
}
# Compute Engine Instance Template for Managed Instance Group
resource "google_compute_instance_template" "sample" {
  name           = "my-instance-template"
  machine_type   = "e2-medium"
  can_ip_forward = false

  disk {
    source_image = data.google_compute_image.sample_image.id
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.self_link
  }
}
# Autoscaler policy 
resource "google_compute_autoscaler" "sample" {
  name   = "my-autoscaler"
  zone   = "us-central1-f"
  target = google_compute_instance_group_manager.sample.id

  autoscaling_policy {
    max_replicas    = 3
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.8
    }
  }
}
# Managed Instance group
resource "google_compute_instance_group_manager" "sample" {
  name = "my-mig"
  zone = "us-central1-f"

  version {
    instance_template = google_compute_instance_template.sample.id
    name              = "primary"
  }
  base_instance_name = "sample"
}

#Service Account for web server
resource "google_service_account" "nginx" {
  account_id = "nginx-demo"
}
#Firewall rule for web server to open port 8080 & ssh port 22 for ansible
resource "google_compute_firewall" "web" {
  name    = "web-access"
  network = google_compute_network.net.name

  allow {
    protocol = "tcp"
    ports    = ["22", "8080"] // port change required
  }

  source_ranges           = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.nginx.email]
}
#
resource "google_compute_instance" "nginx" {
  name         = "nginx"
  machine_type = "e2-micro"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = data.google_compute_image.sample_image.id
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.self_link
    access_config {}
  }

  service_account {
    email  = google_service_account.nginx.email
    scopes = ["cloud-platform"]
  }
  metadata_startup_script = file("./startup-script.sh")

  provisioner "remote-exec" {
    inline = ["echo 'Wait until SSH is ready'"]

    connection {
      type        = "ssh"
      user        = local.ssh_user
      private_key = file(local.private_key_path)
      host        = google_compute_instance.nginx.network_interface.0.network_ip
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook  -i ${google_compute_instance.nginx.network_interface.0.network_ip}, --private-key ${local.private_key_path} nginx.yaml"
  }
}

resource "google_compute_http_health_check" "healthchecks" {
  name               = "webserver-healthcheck"
  check_interval_sec = 10
  timeout_sec        = 5
  request_path       = "/"
  port               = 8080
}

resource "google_compute_target_pool" "web-target-pool" {
  name             = "web-target-pool"
  session_affinity = "NONE"
  region           = "us-central1"

  instances = google_compute_instance.nginx.*.self_link


  health_checks = [
    "${google_compute_http_health_check.healthchecks.name}"
  ]
}

resource "google_compute_forwarding_rule" "web-load-balancer" {
  name                  = "web-lb"
  region                = "us-central1"
  target                = google_compute_target_pool.web-target-pool.self_link
  port_range            = "80"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
}

resource "google_project_iam_custom_role" "stopstart" {
  role_id     = "stopstart"
  title       = "StopStart Role"
  description = "Compute instance stop start role"
  permissions = ["compute.instances.start", "compute.instances.stop"]
}
resource "google_project_iam_binding" "project" {
  project = <Project-id-here>
  role    = "projects/solution-architecture-demos/roles/stopstart"

  members = [
    "user:sanket@gmail.com",
  ]
}