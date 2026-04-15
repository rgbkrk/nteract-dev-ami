packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "m7i.2xlarge"
}

source "amazon-ebs" "base" {
  ami_name      = "nteract-dev-ami-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.aws_region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  ssh_username                = "ubuntu"
  associate_public_ip_address = true
  iam_instance_profile        = "packer-bake-profile"

  # Auto-discover the default VPC and any available subnet in it.
  vpc_filter {
    filters = {
      "isDefault" = "true"
    }
  }
  subnet_filter {
    filters = {
      "state" = "available"
    }
    most_free = true
    random    = false
  }

  # build-ami.sh runs as cloud-init user_data on the bake instance.
  user_data_file = "build-ami.sh"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 200
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "nteract-dev-ami"
    Builder = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.base"]

  # Wait for cloud-init (running build-ami.sh) to finish, then confirm success.
  provisioner "shell" {
    inline = [
      "cloud-init status --wait || true",
      "test -f /var/log/cloud-init-ami-build-done",
    ]
  }
}
