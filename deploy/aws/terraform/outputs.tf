output "instance_id" {
  value = aws_instance.deploy_host.id
}

output "public_ip" {
  value = aws_instance.deploy_host.public_ip
}

output "public_dns" {
  value = aws_instance.deploy_host.public_dns
}

output "ssh_command" {
  value = "ssh ec2-user@${aws_instance.deploy_host.public_ip}"
}
