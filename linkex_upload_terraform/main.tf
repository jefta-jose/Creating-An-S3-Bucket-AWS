data "aws_region" "current" {}

variable "access_key" {
  type = string
}

variable "secret_key" {
  type = string
}
provider "aws" {
  region = "us-east-1"
    access_key = var.access_key
    secret_key = var.secret_key

  default_tags {
    tags = {
      Terraform = "true"
      Project = module.environment.Project
    }
  }
}

terraform {
  backend "s3" {
    bucket = "linkex-upload-terraform-destination-bucket"
    key = "state/terraform.tfstate"
    region = "us-east-1"
    encrypt = true
  }
}

module "environment" {
  source = "./vars"
}

#S3 bucket resource
resource "aws_s3_bucket" "upload_bucket" {
  bucket = "${module.environment.Project}-destination-bucket"
  tags = {
    Name = "${module.environment.Project}_destination_bucket"
  }
}