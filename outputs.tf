output "bucket_repositorio_pdfs" {
  value = "gs://${google_storage_bucket.pdfs.name}/"
}

output "bucket_landing_transaccional" {
  value = "gs://${google_storage_bucket.landing.name}/"
}

output "llave_kms_pdfs" {
  value = google_kms_crypto_key.pdfs.id
}

output "llave_kms_landing" {
  value = google_kms_crypto_key.landing.id
}

output "cuentas_de_servicio" {
  value = {
    ventanilla   = google_service_account.ventanilla.email
    exportador   = google_service_account.exportador.email
    bigquery_etl = google_service_account.bigquery_etl.email
  }
}
