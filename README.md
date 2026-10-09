# Tarea 1 · Estrategia de almacenamiento operativo e ingesta en GCS

## 1. Topología de buckets

| | `gs://sgdea-repositorio-pdfs/` | `gs://sgdea-landing-transaccional/` |
|---|---|---|
| Tipo de dato | No estructurado (PDF escaneado y sellado) | Estructurado (metadatos CSV / JSON / Parquet) |
| Quién escribe | App de Ventanilla (`sa-ventanilla-app`) | Export diario de PostgreSQL (`sa-exportador-postgres`) |
| Quién lee | App de Ventanilla, Silver (`sa-bigquery-etl`), auditores | Capa Bronze de BigQuery (`sa-bigquery-etl`), auditores |
| Ruta de objetos | `documentoscargados/{entradas\|internos\|salidas}/{AAAA}/{MM}/{radicadofinal}.pdf` | `{tabla}/{tabla}_{AAAAMMDD}_1800.csv` |
| Ubicación | Multi-región `US` (alta disponibilidad, igual a BigQuery) | Multi-región `US` |
| Retención | 10 años (TRD), configurable | 365 días |
| Ciclo de vida | Standard → Nearline (90 d) → Coldline (1 año) → Archive (5 años) | Standard → Nearline (30 d) |
| Cifrado en reposo | CMEK `sgdea-key-pdfs` (Cloud KMS, rotación 90 días) | CMEK `sgdea-key-landing` (rotación 90 días) |
| Papelera (soft delete) | 30 días | 7 días |

**Por qué dos buckets:** cada uno tiene un ciclo de vida, una retención, una llave de cifrado y unos permisos distintos. Separarlos aísla los PDF pesados de la operación y de la analítica: la base transaccional solo guarda la ruta del PDF (SLA < 2 s), y BigQuery lee únicamente la Landing Zone.

**Vínculo PDF ↔ metadato:** el nombre del objeto es el número de radicado (`radicadofinal`). Así, la URI `gs://sgdea-repositorio-pdfs/documentoscargados/entradas/2026/10/<radicadofinal>.pdf` se puede reconstruir desde el registro estructurado. La capa Silver (Tarea 3) usa esa regla para validar que el PDF exista.

### Estructura de carpetas (prefijos)

Se conserva la estructura original de la aplicación (`Radicacion_VU/documentoscargados/`), agregando año y mes:

```
gs://sgdea-repositorio-pdfs/
└── documentoscargados/
    ├── entradas/2026/10/<radicadofinal>.pdf
    ├── internos/2026/10/<radicadofinal>.pdf
    └── salidas/2026/10/<radicadofinal>.pdf
```

- **Migración directa:** la ruta local `C:\xampp\htdocs\Radicacion_VU\documentoscargados\...` se traduce 1 a 1 a `gs://sgdea-repositorio-pdfs/documentoscargados/...`; la app solo cambia el prefijo de la ruta.
- **Consulta rápida por radicado:** con el tipo y la fecha del radicado se arma la URI exacta del PDF, sin listar ni buscar en todo el bucket (HU-02).
- **Particionamiento:** las subcarpetas `{AAAA}/{MM}` evitan carpetas planas con miles de archivos y alinean el almacenamiento con la partición por fecha de BigQuery.
- **Seguridad por prefijo:** una condición IAM restringe a `sa-ventanilla-app` para que solo pueda escribir dentro de las tres carpetas de radicados.

## 2. Control de acceso (IAM, mínimo privilegio)

| Identidad | repositorio-pdfs | landing-transaccional |
|---|---|---|
| `sa-ventanilla-app` | `objectCreator` (solo en `documentoscargados/…`) + `objectViewer` | — |
| `sa-exportador-postgres` | — | `objectCreator` |
| `sa-bigquery-etl` | `objectViewer` | `objectViewer` |
| Auditores (opcional) | `objectViewer` | `objectViewer` |

- **Acceso uniforme a nivel de bucket:** se desactivan las ACL por objeto, así que solo cuenta IAM.
- **Prevención de acceso público:** forzada en ambos buckets.
- **Nadie de la operación puede borrar ni sobrescribir:** `objectCreator` solo permite crear objetos nuevos.
- **Logs de auditoría:** Cloud Audit Logs con `DATA_READ` y `DATA_WRITE` registra quién leyó o escribió cada objeto.

## 3. Retención e inmutabilidad

- La **política de retención** impide borrar o reemplazar cualquier objeto antes de que se cumpla su plazo. Así se garantiza la inmutabilidad archivística.
- `lock_retention = true` **bloquea** la política (modelo WORM). Es **irreversible**: después ni el administrador puede acortarla ni borrar el bucket. Para la PoC se deja en `false`; se activa solo en producción.
- GCS no permite combinar retención con versionado de objetos. Por eso no se usa versionado: la retención ya impide perder el original.

## 4. Cifrado

- **En reposo:** CMEK con Cloud KMS. Hay una llave por bucket, con rotación automática cada 90 días. Solo el agente de servicio de Cloud Storage tiene `cryptoKeyEncrypterDecrypter`, así que si la llave se deshabilita, los datos quedan ilegibles.
- **En tránsito:** TLS 1.2+ para toda la API de Cloud Storage. Google lo aplica por defecto; no requiere configuración.

## 5. Archivos

| Archivo | Contenido |
|---|---|
| `versions.tf` | Versión de Terraform y proveedor `google` |
| `variables.tf` | Proyecto, ubicación, sufijo, retenciones, bloqueo y auditores |
| `main.tf` | APIs, KMS, buckets, cuentas de servicio, IAM y audit logs |
| `outputs.tf` | URIs de los buckets, llaves y cuentas creadas |
| `terraform.tfvars.example` | Plantilla de valores |

## 6. Despliegue

```bash
cp terraform.tfvars.example terraform.tfvars   # editar project_id
terraform init
terraform validate
terraform plan
terraform apply
```
