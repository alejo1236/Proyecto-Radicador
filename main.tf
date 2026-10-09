# =====================================================================
# TAREA 1 · Topología de almacenamiento en Google Cloud Storage
#
#   gs://sgdea-repositorio-pdfs/        -> datos NO estructurados (PDF radicados)
#   gs://sgdea-landing-transaccional/   -> Landing Zone de metadatos (CSV/JSON/Parquet)
#
# Seguridad: acceso uniforme (sin ACL), sin acceso público, cifrado CMEK
# (Cloud KMS) con rotación, retención (no borrado/no sobrescritura), logs de auditoría y
# cuentas de servicio con mínimo privilegio.
# =====================================================================

locals {
  pdf_bucket     = "sgdea-repositorio-pdfs${var.bucket_suffix}"
  landing_bucket = "sgdea-landing-transaccional${var.bucket_suffix}"

  labels = {
    sistema  = "sgdea"
    proyecto = "ventanilla-unica"
    gestion  = "terraform"
  }
}

# ---------------------------------------------------------------------
# 1. APIs necesarias
# ---------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "storage.googleapis.com",
    "cloudkms.googleapis.com",
    "iam.googleapis.com",
    "bigquery.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------
# 2. Cifrado en reposo con llave administrada por el cliente (CMEK)
# ---------------------------------------------------------------------
resource "google_kms_key_ring" "sgdea" {
  name       = "sgdea-keyring"
  location   = lower(var.location) # "us" para la multi-región US
  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "pdfs" {
  name            = "sgdea-key-pdfs"
  key_ring        = google_kms_key_ring.sgdea.id
  rotation_period = "7776000s" # rotación automática cada 90 días
  labels          = local.labels
}

resource "google_kms_crypto_key" "landing" {
  name            = "sgdea-key-landing"
  key_ring        = google_kms_key_ring.sgdea.id
  rotation_period = "7776000s"
  labels          = local.labels
}

# Agente de servicio de Cloud Storage: es quien cifra/descifra los objetos
data "google_storage_project_service_account" "gcs" {
  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key_iam_member" "gcs_pdfs" {
  crypto_key_id = google_kms_crypto_key.pdfs.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_kms_crypto_key_iam_member" "gcs_landing" {
  crypto_key_id = google_kms_crypto_key.landing.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# ---------------------------------------------------------------------
# 3. Bucket de documentos NO estructurados: PDFs radicados
#    Ruta (misma estructura que la app local C:\xampp\htdocs\Radicacion_VU\documentoscargados):
#    gs://sgdea-repositorio-pdfs/documentoscargados/{entradas|internos|salidas}/{AAAA}/{MM}/{radicadofinal}.pdf
# ---------------------------------------------------------------------
resource "google_storage_bucket" "pdfs" {
  name     = local.pdf_bucket
  location = var.location
  labels   = merge(local.labels, { zona = "repositorio-pdfs", tipo_dato = "no-estructurado" })

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true       # solo IAM, sin ACL por objeto
  public_access_prevention    = "enforced" # nunca público
  force_destroy               = false

  # La retención impide borrar o sobrescribir cada PDF hasta que venza.
  # (GCS no permite combinarla con versionado: la retención ya cubre ese riesgo.)
  retention_policy {
    retention_period = var.pdf_retention_days * 86400
    is_locked        = var.lock_retention
  }

  soft_delete_policy {
    retention_duration_seconds = 30 * 86400 # papelera de 30 días
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.pdfs.id
  }

  # Ciclo de vida: abarata el almacenamiento a medida que el PDF envejece
  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  lifecycle_rule {
    condition { age = 365 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  lifecycle_rule {
    condition { age = 1825 }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_pdfs]
}

# ---------------------------------------------------------------------
# 4. Bucket Landing Zone: metadatos transaccionales (CSV/JSON/Parquet)
#    Ruta: gs://sgdea-landing-transaccional/{tabla}/{tabla}_{AAAAMMDD}_1800.csv
# ---------------------------------------------------------------------
resource "google_storage_bucket" "landing" {
  name     = local.landing_bucket
  location = var.location
  labels   = merge(local.labels, { zona = "landing", tipo_dato = "estructurado" })

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  retention_policy {
    retention_period = var.landing_retention_days * 86400
    is_locked        = var.lock_retention
  }

  soft_delete_policy {
    retention_duration_seconds = 7 * 86400
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.landing.id
  }

  # Ya cargados a Bronze, los archivos se consultan poco: se pasan a Nearline
  lifecycle_rule {
    condition { age = 30 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_landing]
}

# ---------------------------------------------------------------------
# 5. Cuentas de servicio (mínimo privilegio)
# ---------------------------------------------------------------------
resource "google_service_account" "ventanilla" {
  account_id   = "sa-ventanilla-app"
  display_name = "SGDEA - Aplicación Ventanilla Única (sube y consulta PDFs)"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "exportador" {
  account_id   = "sa-exportador-postgres"
  display_name = "SGDEA - Export diario PostgreSQL -> Landing Zone"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "bigquery_etl" {
  account_id   = "sa-bigquery-etl"
  display_name = "SGDEA - Pipelines BigQuery (Bronze/Silver/Gold)"
  depends_on   = [google_project_service.apis]
}

# ---------------------------------------------------------------------
# 6. IAM a nivel de bucket
#    Nadie de la operación tiene permiso de BORRAR objetos.
# ---------------------------------------------------------------------

# --- Repositorio de PDFs ---
resource "google_storage_bucket_iam_member" "pdfs_app_create" {
  bucket = google_storage_bucket.pdfs.name
  role   = "roles/storage.objectCreator" # crea, no borra ni sobrescribe
  member = "serviceAccount:${google_service_account.ventanilla.email}"

  # La app solo puede escribir dentro de documentoscargados/{entradas|internos|salidas}/
  condition {
    title       = "solo-documentoscargados"
    description = "Escritura limitada a las 3 carpetas de radicados"
    expression  = <<-EOT
      resource.name.startsWith("projects/_/buckets/${local.pdf_bucket}/objects/documentoscargados/entradas/") ||
      resource.name.startsWith("projects/_/buckets/${local.pdf_bucket}/objects/documentoscargados/internos/") ||
      resource.name.startsWith("projects/_/buckets/${local.pdf_bucket}/objects/documentoscargados/salidas/")
    EOT
  }
}

resource "google_storage_bucket_iam_member" "pdfs_app_read" {
  bucket = google_storage_bucket.pdfs.name
  role   = "roles/storage.objectViewer" # consulta del PDF por número de radicado
  member = "serviceAccount:${google_service_account.ventanilla.email}"
}

resource "google_storage_bucket_iam_member" "pdfs_etl_read" {
  bucket = google_storage_bucket.pdfs.name
  role   = "roles/storage.objectViewer" # Silver valida que el PDF exista (Tarea 3)
  member = "serviceAccount:${google_service_account.bigquery_etl.email}"
}

# --- Landing Zone ---
resource "google_storage_bucket_iam_member" "landing_export_create" {
  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.exportador.email}"
}

resource "google_storage_bucket_iam_member" "landing_etl_read" {
  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectViewer" # tablas externas de Bronze (Tarea 2)
  member = "serviceAccount:${google_service_account.bigquery_etl.email}"
}

# --- Auditores (solo lectura en ambos) ---
resource "google_storage_bucket_iam_member" "auditores_pdfs" {
  for_each = toset(var.auditores)
  bucket   = google_storage_bucket.pdfs.name
  role     = "roles/storage.objectViewer"
  member   = each.value
}

resource "google_storage_bucket_iam_member" "auditores_landing" {
  for_each = toset(var.auditores)
  bucket   = google_storage_bucket.landing.name
  role     = "roles/storage.objectViewer"
  member   = each.value
}

# ---------------------------------------------------------------------
# 7. Logs de auditoría de acceso a datos (quién leyó/escribió cada objeto)
#    Quedan en Cloud Logging. OJO: si el proyecto ya tiene audit config
#    para storage, este recurso la reemplaza.
# ---------------------------------------------------------------------
resource "google_project_iam_audit_config" "storage" {
  project = var.project_id
  service = "storage.googleapis.com"

  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}
