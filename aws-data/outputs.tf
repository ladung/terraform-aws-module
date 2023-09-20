output "aws_region" {
  description = "Details about selected AWS region"
  value       = data.aws_region.selected
}

output "available_aws_availability_zones_names" {
  description = "A list of the Availability Zone names available to the account"
  value       = data.aws_availability_zones.available.names
}

output "available_aws_availability_zones_zone_ids" {
  description = "A list of the Availability Zone IDs available to the account"
  value       = data.aws_availability_zones.available.zone_ids
}

output "aws_ami_ids" {
  description = "A list of AMI IDs"
  value       = { for k, v in data.aws_ami.this : k => tomap({ id = v.image_id, root_device_name = v.root_device_name }) }
}

output "ubuntu_1804_aws_ami_id" {
  description = "AMI ID of Ubuntu 18.04"
  value       = data.aws_ami.ubuntu_1804.id
}

output "ubuntu_2004_aws_ami_id" {
  description = "AMI ID of Ubuntu 20.04"
  value       = data.aws_ami.ubuntu_2004.id
}
