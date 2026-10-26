output "web_service_uri" {
  description = "The main URI in which this Service is serving traffic."
  value       = module.web.service_uri
}

output "db_connection_name" {
  description = "Cloud SQL connection name."
  value       = module.db.instance_connection_name
}
