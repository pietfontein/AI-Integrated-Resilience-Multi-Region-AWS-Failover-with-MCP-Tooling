bucket         = "tf-state-resilience-backbone"
key            = "global/terraform.tfstate"
region         = "af-south-1"
encrypt        = true
use_lockfile   = true

access_key                  = "test"
secret_key                  = "test"
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_requesting_account_id  = true
use_path_style              = true

endpoints = {
  s3 = "http://127.0.0.1:4566"
  sts = "http://127.0.0.1:4566"
}
