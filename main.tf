# Requirements
# instance group, template, backend, health-check
# network, subnetwork, forwarding rules, firewalls, url maps, cloud router


# create network and subnetworks
resource "google_compute_network" "my-internal-app-network" {
  name                    = "my-internal-app-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet-a" {
  name          = "subnet-a"
  ip_cidr_range = "10.0.1.0/24"
  region        = "europe-west4"
  network       = google_compute_network.my-internal-app-network.self_link
}

resource "google_compute_subnetwork" "subnet-b" {
  name          = "subnet-b"
  ip_cidr_range = "10.10.0.0/16"
  region        = "europe-west1"
  network       = google_compute_network.my-internal-app-network.self_link
}
#create the required firewalls
resource "google_compute_firewall" "app-allow-icmp" {
  name          = "app-allow-icmp"
  network       = google_compute_network.my-internal-app-network.self_link
  source_ranges = ["10.10.0.0/16", "10.0.1.0/24"]
  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "app-allow-ssh-rdp" {
  name          = "app-allow-ssh-rdp"
  network       = google_compute_network.my-internal-app-network.self_link
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }
}

resource "google_compute_firewall" "fw-allow-health-checks" {
  name          = "fw-allow-health-checks"
  network       = google_compute_network.my-internal-app-network.self_link
  source_ranges = ["10.10.0.0/16", "10.0.1.0/24"]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}
resource "google_compute_firewall" "fw-allow-lb-access" {
  name          = "fw-allow-lb-access"
  network       = google_compute_network.my-internal-app-network.self_link
  source_ranges = ["10.10.0.0/16"]
  allow {
    protocol = "all"
  }
}


resource "google_compute_router" "nat-router-us-central1" {
  name    = "nat-router-us-central1"
  region = "europe-west4"
  network = google_compute_network.my-internal-app-network.self_link
  bgp {
    asn               = 64514
    advertise_mode    = "CUSTOM"
    advertised_groups = ["ALL_SUBNETS"]
    advertised_ip_ranges {
      range = "10.10.0.0/16"
    }
    advertised_ip_ranges {
      range = "10.0.1.0/24"
    }
  }
}

#regional mig 1
resource "google_compute_region_instance_group_manager" "instance-group-1" {
  name   = "instance-group-1"
  region = "europe-west4"
  version {
    instance_template = google_compute_instance_template.instance-template-1.id
    name              = "primary"
  }
  base_instance_name = "instance-group-1"
  target_size        = 2
}

#region mig 2
resource "google_compute_region_instance_group_manager" "instance-group-2" {
  name   = "instance-group-2"
  region = "europe-west1"
  version {
    instance_template = google_compute_instance_template.instance-template-2.id
    name              = "primary"
  }
  base_instance_name = "instance-group-1"
  target_size        = 2
}

# Instance template for the instance-group-1
resource "google_compute_instance_template" "instance-template-1" {
  name         = "instance-templatea"
  machine_type = "e2-small"
  #tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.my-internal-app-network.id
    subnetwork = google_compute_subnetwork.subnet-a.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }
}

# Instance template for the instance-group-2
resource "google_compute_instance_template" "instance-template-2" {
  name         = "instance-templatee"
  machine_type = "e2-small"
  #tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.my-internal-app-network.id
    subnetwork = google_compute_subnetwork.subnet-b.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }
}

#create a vm for testing
resource "google_compute_instance" "utility-vm" {
  name         = "utility-vm"
  zone         = "europe-west1-b"
  machine_type = "n1-standard-1"
  boot_disk {
      initialize_params {
          image = "debian-cloud/debian-10"
      }
  }
  network_interface {
    #network_ip = "10.10.20.50"
    network    = google_compute_network.my-internal-app-network.self_link
    subnetwork = google_compute_subnetwork.subnet-b.self_link
    access_config {

    }
  }
}

# backend service
resource "google_compute_region_backend_service" "default" {
  name                  = "default"
  #provider              = google-beta
  region                = "europe-west4"
  protocol              = "HTTP"
  #enable_cdn = "true"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 10
  health_checks         = [google_compute_region_health_check.default.id]
  backend {
    group           = google_compute_region_instance_group_manager.instance-group-1.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# health check
resource "google_compute_region_health_check" "default" {
  name     = "default-health"
  provider = google-beta
  region   = "europe-west4"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "proxy-subnet"
  provider      = google-beta
  ip_cidr_range = "10.0.10.0/24"
  region        = "europe-west4"
  purpose       = "INTERNAL_HTTPS_LOAD_BALANCER"
  role          = "ACTIVE"
  network       = google_compute_network.my-internal-app-network.self_link
}

# forwarding rule
resource "google_compute_forwarding_rule" "google_compute_forwarding_rule" {
  name                  = "forwarding-rule1"
  provider              = google-beta
  region                = "europe-west4"
  depends_on            = [google_compute_subnetwork.proxy_subnet]
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.default.id
  network               = google_compute_network.my-internal-app-network.self_link
  subnetwork            = google_compute_subnetwork.subnet-a.id
  network_tier          = "PREMIUM"
}

# HTTP target proxy
resource "google_compute_region_target_http_proxy" "default" {
  name     = "target-http-proxy"
  provider = google-beta
  region   = "europe-west4"
  url_map  = google_compute_region_url_map.default.id
}

# URL map
resource "google_compute_region_url_map" "default" {
  name            = "regional-url-map"
  provider        = google-beta
  region          = "europe-west4"
  default_service = google_compute_region_backend_service.default.id
}
