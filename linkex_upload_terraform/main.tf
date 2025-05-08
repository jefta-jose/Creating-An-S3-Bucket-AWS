# Get current AWS region data for potential use in configuration
data "aws_region" "current" {}

# AWS credentials variables - should be passed securely (never hardcoded)
variable "access_key" {
  type = string
}

variable "secret_key" {
  type = string
}

# Configure the AWS provider with required credentials and default tags
provider "aws" {
  region     = "us-east-1"
  access_key = var.access_key
  secret_key = var.secret_key

  # Apply default tags to all resources created by this provider
  default_tags {
    tags = {
      Terraform = "true"          # Indicates resource was created by Terraform
      Project   = module.environment.Project  # Gets project name from environment module
    }
  }
}

# Configure remote backend to store Terraform state in S3 for team collaboration
terraform {
  backend "s3" {
    bucket   = "linkex-upload-terraform-destination-bucket"  # State bucket name
    key      = "state/terraform.tfstate"  # Path to store state file
    region   = "us-east-1"               # Region for state bucket
    encrypt  = true                      # Enable encryption for state file
  }
}

# Import environment-specific variables from separate module
module "environment" {
  source = "./vars"
}

# Create S3 bucket for upload destination with project-specific naming
resource "aws_s3_bucket" "upload_bucket" {
  bucket = "${module.environment.Project}-destination-bucket"  # Unique bucket name
  tags = {
    Name = "${module.environment.Project}_destination_bucket"  # Descriptive tag
  }
}

# Create IAM user for upload functionality with least privilege approach
resource "aws_iam_user" "linkex_upload_user" {
  name = "linkex-upload-user"

  tags = {
    Name = "linkex-upload-user"  # Standard naming convention for tracking
  }
}

# IAM policy document defining permissions for S3 bucket access
data "aws_iam_policy_document" "s3_bucket_access" {
  statement {
    effect = "Allow"  # Explicitly allow these actions

    # Permissions granted:
    # - GetObject: Read objects from bucket
    # - PutObject: Write objects to bucket
    # - ListBucket: View bucket contents
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket"
    ]

    # Resources this policy applies to:
    # - The bucket itself
    # - All objects within the bucket (* wildcard)
    resources = [
      aws_s3_bucket.upload_bucket.arn,
      "${aws_s3_bucket.upload_bucket.arn}/*"
    ]
  }
}

# Create IAM policy from the policy document
resource "aws_iam_policy" "s3_bucket_access" {
  name        = "${module.environment.Project}-s3-bucket-access-policy"
  description = "Policy allowing access to ${aws_s3_bucket.upload_bucket.bucket} bucket"
  
  # The policy document is converted to JSON as required by AWS IAM
  policy      = data.aws_iam_policy_document.s3_bucket_access.json

  tags = {
    Name = "${module.environment.Project}-s3-bucket-access-policy"  # Consistent tagging
  }
}

# Attach the S3 access policy to the IAM user
# This grants the user the permissions defined in the policy
resource "aws_iam_user_policy_attachment" "s3_bucket_access" {
  user       = aws_iam_user.linkex_upload_user.name  # Reference to created user
  policy_arn = aws_iam_policy.s3_bucket_access.arn   # Reference to policy ARN
}

# IAM Role for the Lambda
resource "aws_iam_role" "lambda_exec_role" {
  name = "${module.environment.Project}-lambda-role"

  assume_role_policy = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": "lambda.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }
        EOF
}

# attach basic execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# create the lambda function
resource "aws_lambda_function" "s3_upload_trigger" {
  function_name = "${module.environment.Project}-upload-trigger"
  role = aws_iam_role.lambda_exec_role.arn
  handler = "index.handler"
  runtime = "python3.12"
  timeout = 300

  filename = "lambda.zip"
  source_code_hash = filebase64sha256("lambda.zip")

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.upload_bucket.bucket
    }
  }

  tags = {
    Name = "${module.environment.Project}-upload-trigger"
  }
}