# ---------------------------------------------------------------------
# Variables de la Tarea 1 · Almacenamiento operativo e ingesta en GCS
# ---------------------------------------------------------------------

variable "project_id" {
  description = "ID del proyecto de Google Cloud."
  type        = string
}

variable "region" {
  description = "Región por defecto del proveedor."
  type        = string
  default     = "us-central1"
}

variable "location" {
  description = "Ubicación de los buckets. Debe coincidir con la del dataset de BigQuery (Tarea 2)."
  type        = string
  default     = "US"
}

variable "bucket_suffix" {
  description = "Sufijo opcional. Los nombres de bucket son únicos en todo GCP; si 'sgdea-repositorio-pdfs' ya existe, use p. ej. '-uao'."
  type        = string
  default     = ""
}

# --- Retención (Tabla de Retención Documental) -----------------------
variable "pdf_retention_days" {
  description = "Días que un PDF radicado NO puede borrarse ni sobrescribirse."
  type        = number
  default     = 3650 # 10 años
}

variable "landing_retention_days" {
  description = "Días que un archivo de metadatos de la Landing Zone NO puede borrarse (trazabilidad de la capa Bronze)."
  type        = number
  default     = 365
}

variable "lock_retention" {
  description = "Bloquear la política de retención (WORM). IRREVERSIBLE: ni el dueño del proyecto podrá borrar los objetos ni el bucket hasta que venza. Dejar en false para la PoC académica."
  type        = bool
  default     = false
}

# --- Personas con acceso de solo lectura (opcional) -------------------
variable "auditores" {
  description = "Miembros con lectura de ambos buckets, p. ej. [\"user:alguien@uao.edu.co\"]."
  type        = list(string)
  default     = []
}
