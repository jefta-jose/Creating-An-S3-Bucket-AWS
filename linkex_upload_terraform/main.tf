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

# myself as user was created in aws ui by Aaron
# then myself, I was able to create an access key and secret key 
# which I later used in my ci-cd to provision resources

# this is the same -> we are creating a user 
# and this user will have secrets and access key that they can use
# depending on their level of permission


# in this case we have just created a user who so far has no access to any resources
resource "aws_iam_user" "linkex_upload_user" {
  name = "linkex-upload-user"

  tags = {
    Name = "linkex-upload-user"
  }
}


# we need to grant our user read && write to our s3
# so we define that policy
data "aws_iam_policy_document" "s3_bucket_access" {
  statement {
    effect = "Allow"

    # this block defines what actions can be done on the  bucket
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket"
    ]

    # this block defines what can you do the above to
    resources = [
      # this gives us access to arn but nothing that is nested
      aws_s3_bucket.upload_bucket.arn,
      # access to everything inside the bucket
      "${aws_s3_bucket.upload_bucket.arn}/*"
    ]

  }
}

# now lets create an s3 bucket access IAM policy
resource "aws_iam_policy" "s3_bucket_access" {
  name = "${module.environment.Project}-s3-bucket-access-policy"
  description = "This policy allows access to ${aws_s3_bucket.upload_bucket.bucket}"
  # why a json though ?
  policy = data.aws_iam_policy_document.s3_bucket_access.json

  #notice how we are tagging all our resources this makes it easer
  tags = {
    Name = "${module.environment.Project}-s3-bucket-access-policy"
  }
}


# at this stage we have the policy, the bucket and the user
# now we need to attach the policy to the user 

# attach the s3 bucket access policy to the IAM user
resource "aws_iam_user_policy_attachment" "s3_bucket_access" {
  user = aws_iam_user.linkex_upload_user.name
  policy_arn = aws_iam_policy.s3_bucket_access.arn
}