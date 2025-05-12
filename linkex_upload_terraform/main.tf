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

# Creates an IAM role that AWS Lambda can assume to execute your function
# This role defines what AWS services can assume it (in this case, Lambda)
resource "aws_iam_role" "lambda_exec_role" {
  name = "${module.environment.Project}-lambda-role"

  # The trust policy that specifies who can assume this role
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

# Attaches the basic Lambda execution policy to the IAM role
# This provides permissions for Lambda to write logs to CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Creates a ZIP archive of the Lambda function code
# This packages your Lambda code for deployment
data "archive_file" "zip_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"  # Source directory containing Lambda code
  output_path = "${path.module}/../lambda.zip"  # Output path for the ZIP file
}

# Creates the Lambda function resource
# This defines the function's configuration including runtime, handler, and environment
resource "aws_lambda_function" "s3_upload_trigger" {
  function_name = "${module.environment.Project}-upload-trigger"  # Unique name for the Lambda function
  role          = aws_iam_role.lambda_exec_role.arn  # IAM role the function will assume
  handler       = "index.handler"  # Entry point for the Lambda function
  runtime       = "python3.10"  # Python 3.10 runtime environment
  timeout       = 300  # Maximum execution time in seconds (5 minutes)

  # Ensure IAM permissions are set before creating the Lambda
  depends_on = [aws_iam_role_policy_attachment.lambda_basic_execution]

  filename = "${path.module}/../lambda.zip"  # Path to the deployment package

  # Environment variables passed to the Lambda function
  environment {
    variables = {
        SECRETS_MANAGER_ARN = aws_secretsmanager_secret.secret.arn
    }
  }

  tags = {
    Name = "${module.environment.Project}-upload-trigger"  # Resource tag for identification
  }
}

# Grants S3 permission to invoke the Lambda function
# This permission is required for S3 event notifications to trigger the Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"  # Unique identifier for the permission
  action        = "lambda:InvokeFunction"  # The action being permitted
  function_name = aws_lambda_function.s3_upload_trigger.arn  # The Lambda function to allow
  principal     = "s3.amazonaws.com"  # The service being granted permission
  source_arn    = aws_s3_bucket.upload_bucket.arn  # Restricts permission to this specific S3 bucket
}

# Configures S3 bucket notifications to trigger the Lambda function
# This sets up the event-driven architecture between S3 and Lambda
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.upload_bucket.id  # The S3 bucket to monitor

  # Lambda function configuration for the notification
  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_upload_trigger.arn  # Lambda to trigger
    events              = ["s3:ObjectCreated:*"]  # Trigger on any object creation event
  }

  # Ensure Lambda permissions are set before configuring notifications
  depends_on = [aws_lambda_permission.allow_s3]
}

# Create the log group
resource "aws_cloudwatch_log_group" "lambda-log-group" {
  name              = "/aws/lambda/${aws_lambda_function.s3_upload_trigger.function_name}"
  retention_in_days = 30

  depends_on = [ aws_lambda_function.s3_upload_trigger ]
}

resource "aws_secretsmanager_secret" "secret" {
  name                           = "${module.environment.Project}-secret-manager-2"
  force_overwrite_replica_secret = false
  recovery_window_in_days        = 30

  tags = {
    Name        = "${module.environment.Project}-secret-manager"
  }
}