output "instance_public_ip" {
  description = "Public IP of the web app instance"
  value       = aws_instance.app.public_ip
}

output "instance_url_http" {
  description = "HTTP URL to test the app"
  value       = "http://${aws_instance.app.public_ip}"
}
