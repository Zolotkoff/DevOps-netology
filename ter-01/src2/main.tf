terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
    random = {
      source = "hashicorp/random"
    }
  }
  required_version = "~>1.12.0"
}

provider "docker" {
  host = "ssh://ubuntu@62.84.124.66"
  ssh_opts = ["-o", "StrictHostKeyChecking=no", "-i", "/home/zolotkoff/.ssh/id_ed25519"]
}

resource "random_password" "mysql_root" {
  length  = 16
  special = false
}

resource "random_password" "mysql_user" {
  length  = 16
  special = false
}

resource "docker_image" "mysql" {
  name         = "mysql:8"
  keep_locally = true
}

resource "docker_container" "mysql" {
  image = docker_image.mysql.image_id
  name  = "mysql_${random_password.mysql_root.result}"

  ports {
    internal = 3306
    external = 3306
    ip       = "127.0.0.1"
  }

  env = [
    "MYSQL_ROOT_PASSWORD=${random_password.mysql_root.result}",
    "MYSQL_DATABASE=wordpress",
    "MYSQL_USER=wordpress",
    "MYSQL_PASSWORD=${random_password.mysql_user.result}",
    "MYSQL_ROOT_HOST=%",
  ]
}
