terraform {
  backend "s3" {
    bucket       = "ecs-supply-chain-state-104423791048-eu-central-1-an"
    key          = "terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
