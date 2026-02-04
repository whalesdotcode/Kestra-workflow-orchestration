# NYC Taxi Data Pipeline

A multi-cloud data engineering project that extracts, loads, and transforms NYC taxi trip data using **Kestra** as the orchestration layer, with parallel implementations on **AWS** (S3 + Athena) and **GCP** (GCS + BigQuery).


## Table of Contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Infrastructure (Terraform)](#infrastructure-terraform)
- [Kestra Workflow](#kestra-workflow)
- [AWS Flow](#aws-flow)
- [GCP Flow](#gcp-flow)
- [End-to-End Flow](#end-to-end-flow)
- [How to Run](#how-to-run)
- [Best Practices & Notes](#best-practices--notes)

---

## Project Overview

This project implements a production-ready ELT (Extract, Load, Transform) pipeline for NYC Taxi trip data. The pipeline:

1. **Extracts** compressed CSV files from the [NYC TLC Data Repository](https://github.com/DataTalksClub/nyc-tlc-data/releases)
2. **Loads** raw data into cloud storage (S3 or GCS)
3. **Transforms** data using SQL-based analytics engines (Athena or BigQuery)
4. **Deduplicates** records using MD5 hashing to ensure idempotency
5. **Stores** final data in optimized formats (Iceberg tables on AWS, partitioned tables on GCP)


### Use Case

This pipeline is designed for analytics teams who need to:
- Analyze taxi trip patterns across NYC
- Build dashboards and reports on trip volumes, fares, and trends
- Maintain a reliable, deduplicated data warehouse
- Support both AWS and GCP environments

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DATA SOURCE                                     │
│                    GitHub (NYC TLC Data - CSV.gz)                           │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           KESTRA ORCHESTRATION                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │   Extract   │──│    Load     │──│  Transform  │──│   Merge     │        │
│  │  (Python)   │  │  (S3/GCS)   │  │ (Athena/BQ) │  │ (Dedupe)    │        │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘        │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
┌───────────────────────────────┐ ┌───────────────────────────────┐
│            AWS                │ │            GCP                │
│  ┌─────────────────────────┐  │ │  ┌─────────────────────────┐  │
│  │     S3 Data Lake        │  │ │  │   Google Cloud Storage  │  │
│  │  - Raw CSVs             │  │ │  │   - Raw CSVs            │  │
│  │  - Parquet (Iceberg)    │  │ │  └─────────────────────────┘  │
│  └─────────────────────────┘  │ │                               │
│  ┌─────────────────────────┐  │ │  ┌─────────────────────────┐  │
│  │     AWS Athena          │  │ │  │      BigQuery           │  │
│  │  - External Tables      │  │ │  │  - External Tables      │  │
│  │  - Iceberg Tables       │  │ │  │  - Partitioned Tables   │  │
│  │  - MERGE operations     │  │ │  │  - MERGE operations     │  │
│  └─────────────────────────┘  │ │  └─────────────────────────┘  │
└───────────────────────────────┘ └───────────────────────────────┘
```

---

## Infrastructure (Terraform)

Terraform is used to provision and manage AWS cloud resources in a reproducible, version-controlled manner.

### Resources Provisioned

| Resource | Name | Purpose |
|----------|------|---------|
| **S3 Bucket** | `ny-taxi-data-lake-{account_id}` | Stores raw CSV files and Iceberg table data |
| **S3 Bucket** | `ny-taxi-athena-results-{account_id}` | Stores Athena query results |
| **Athena Database** | `ny_taxi` | Logical database for taxi data tables |
| **Athena Workgroup** | `ny-taxi-workgroup` | Workgroup with CloudWatch metrics enabled |

### Terraform Configuration

```hcl
# main.tf - Key Resources

# S3 bucket for raw data and Iceberg tables
resource "aws_s3_bucket" "data_lake" {
  bucket        = "ny-taxi-data-lake-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

# S3 bucket for Athena query results
resource "aws_s3_bucket" "athena_results" {
  bucket        = "ny-taxi-athena-results-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

# Athena database
resource "aws_athena_database" "taxi_database" {
  name   = "ny_taxi"
  bucket = aws_s3_bucket.athena_results.id
}

# Athena workgroup with result configuration
resource "aws_athena_workgroup" "taxi_workgroup" {
  name          = "ny-taxi-workgroup"
  force_destroy = true

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/results/"
    }
  }
}
```

### Terraform Outputs

After running `terraform apply`, you'll receive:

- `s3_data_lake_bucket` - Bucket name for storing taxi data
- `s3_athena_results_bucket` - Bucket name for Athena results
- `athena_database_name` - Database name (`ny_taxi`)
- `aws_account_id` - Your AWS account ID
- `aws_region` - Configured AWS region

---

## Kestra Workflow

[Kestra](https://kestra.io/) is an open-source orchestration platform that manages the entire data pipeline. It provides:

- **Declarative YAML workflows** - Easy to read, version, and maintain
- **Built-in cloud integrations** - Native plugins for AWS, GCP, and more
- **Error handling** - Automatic retries and failure notifications
- **UI-based execution** - Run workflows with custom inputs via web interface

### Workflow Structure

Both AWS and GCP workflows follow the same logical structure:

```yaml
id: 08_aws_taxi  # or 08_gcp_taxi
namespace: zoomcamp

inputs:
  - taxi: [yellow, green]    # Taxi type selection
  - year: [2019, 2020, 2021] # Year selection
  - month: [01-12]           # Month selection
  - askAI: string            # Optional AI assistant

tasks:
  1. set_label        # Tag execution with metadata
  2. extract          # Download and decompress data
  3. upload           # Load to cloud storage
  4. if_yellow_taxi   # Yellow taxi-specific transformations
  5. if_green_taxi    # Green taxi-specific transformations
  6. purge_files      # Cleanup temporary files
```


## AWS Flow

The AWS implementation uses **S3** for storage and **Athena with Iceberg tables** for analytics.

### Step-by-Step Breakdown

#### 1. Extract Data

```yaml
- id: extract
  type: io.kestra.plugin.scripts.python.Script
  containerImage: python:3.11-slim
  beforeCommands:
    - pip install requests --quiet
  script: |
    import requests
    import gzip
    from io import BytesIO

    url = f"https://github.com/DataTalksClub/nyc-tlc-data/releases/download/{taxi}/{filename}.gz"
    response = requests.get(url, timeout=300)
    
    with gzip.GzipFile(fileobj=BytesIO(response.content)) as gz:
        with open(filename, 'wb') as f:
            shutil.copyfileobj(gz, f)
```

**What it does:**
- Runs in a Python 3.11 Docker container
- Downloads compressed CSV from GitHub
- Decompresses using gzip
- Outputs the CSV file for the next step

#### 2. Upload to S3

```yaml
- id: upload_to_s3
  type: io.kestra.plugin.aws.cli.AwsCLI
  commands:
    - aws s3 cp {{render(vars.data)}} s3://{{kv('S3_DATA_LAKE_BUCKET')}}/{{inputs.taxi}}_tripdata/year={{inputs.year}}/month={{inputs.month}}/{{render(vars.file)}}
```

**S3 Structure:**
```
s3://ny-taxi-data-lake-{account_id}/
├── yellow_tripdata/
│   └── year=2019/
│       └── month=01/
│           └── yellow_tripdata_2019-01.csv
├── green_tripdata/
│   └── year=2019/
│       └── month=01/
│           └── green_tripdata_2019-01.csv
└── parquet/
    ├── yellow/    # Iceberg table data
    └── green/     # Iceberg table data
```

#### 3. Create Iceberg Table

```yaml
- id: athena_green_create_table
  type: io.kestra.plugin.aws.athena.Query
  query: |
    CREATE TABLE IF NOT EXISTS green_tripdata (
        unique_row_id string,
        filename string,
        VendorID string,
        lpep_pickup_datetime timestamp,
        lpep_dropoff_datetime timestamp,
        ...
    )
    LOCATION 's3://{{kv('S3_DATA_LAKE_BUCKET')}}/parquet/{{inputs.taxi}}/'
    TBLPROPERTIES ('table_type'='ICEBERG')
```


#### 4. Create External Table (Staging)

```yaml
- id: athena_green_create_external_table
  type: io.kestra.plugin.aws.athena.Query
  query: |
    CREATE EXTERNAL TABLE {{render(vars.table)}}_ext (...)
    ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe'
    WITH SERDEPROPERTIES (
        'field.delim' = ',',
        'skip.header.line.count' = '1'
    )
    LOCATION 's3://{{kv('S3_DATA_LAKE_BUCKET')}}/{{inputs.taxi}}_tripdata/year={{inputs.year}}/month={{inputs.month}}/'
```

**Purpose:** Points directly to the raw CSV in S3 for reading.

#### 5. Create Temporary Table with Deduplication

```yaml
- id: athena_green_tmp_create
  type: io.kestra.plugin.aws.athena.Query
  query: |
    CREATE TABLE {{render(vars.table)}}_tmp AS
    SELECT 
        unique_row_id, filename, VendorID, ...
    FROM (
        SELECT
            to_hex(md5(to_utf8(concat(
                coalesce(cast(VendorID as varchar), ''),
                coalesce(cast(lpep_pickup_datetime as varchar), ''),
                coalesce(cast(lpep_dropoff_datetime as varchar), ''),
                coalesce(cast(PULocationID as varchar), ''),
                coalesce(cast(DOLocationID as varchar), '')
            )))) as unique_row_id,
            '{{render(vars.file)}}' as filename,
            *,
            ROW_NUMBER() OVER (
                PARTITION BY VendorID, lpep_pickup_datetime, lpep_dropoff_datetime, PULocationID, DOLocationID
                ORDER BY lpep_pickup_datetime
            ) as rn
        FROM {{render(vars.table)}}_ext
    )
    WHERE rn = 1
```

**Deduplication Logic:**
- `MD5 hash` creates a unique identifier from key columns
- `ROW_NUMBER()` eliminates duplicates within the source CSV
- Only rows with `rn = 1` are kept

#### 6. Merge into Final Table

```yaml
- id: green_merge
  type: io.kestra.plugin.aws.athena.Query
  query: |
    MERGE INTO green_tripdata T
    USING {{render(vars.table)}}_tmp S
    ON S.unique_row_id = T.unique_row_id
    WHEN NOT MATCHED THEN
      INSERT (unique_row_id, filename, VendorID, ...)
      VALUES (S.unique_row_id, S.filename, S.VendorID, ...)
```

**Why MERGE?**
- Only inserts records that don't already exist
- Safe to re-run the same month multiple times
- Prevents data duplication

#### 7. Cleanup

```yaml
- id: athena_green_cleanup
  query: DROP TABLE IF EXISTS {{render(vars.table)}}_ext

- id: athena_green_cleanup_tmp
  query: DROP TABLE IF EXISTS {{render(vars.table)}}_tmp
```

**Purpose:** Removes temporary tables to keep the Glue catalog clean.

### AWS Services Used

| Service | Purpose |
|---------|---------|
| **S3** | Object storage for raw CSVs and Iceberg data |
| **Athena** | Serverless SQL query engine |
| **Glue Data Catalog** | Metadata store for tables (implicit) |
| **Iceberg** | Table format for ACID transactions |

---

## GCP Flow

The GCP implementation uses **Google Cloud Storage** for storage and **BigQuery** for analytics.

### Step-by-Step Breakdown

#### 1. Extract Data

```yaml
- id: extract
  type: io.kestra.plugin.scripts.shell.Commands
  outputFiles:
    - "*.csv"
  commands:
    - wget -qO- https://github.com/DataTalksClub/nyc-tlc-data/releases/download/{{inputs.taxi}}/{{render(vars.file)}}.gz | gunzip > {{render(vars.file)}}
```

**Difference from AWS:** Uses shell commands with wget/gunzip instead of Python.

#### 2. Upload to GCS

```yaml
- id: upload_to_gcs
  type: io.kestra.plugin.gcp.gcs.Upload
  from: "{{render(vars.data)}}"
  to: "{{render(vars.gcs_file)}}"
```

**GCS Structure:**
```
gs://bucket-name/
├── yellow_tripdata_2019-01.csv
├── yellow_tripdata_2019-02.csv
├── green_tripdata_2019-01.csv
└── ...
```

#### 3. Create Main Table

```yaml
- id: bq_green_tripdata
  type: io.kestra.plugin.gcp.bigquery.Query
  sql: |
    CREATE TABLE IF NOT EXISTS `{{kv('GCP_PROJECT_ID')}}.{{kv('GCP_DATASET')}}.green_tripdata`
    (
        unique_row_id BYTES,
        filename STRING,
        VendorID STRING,
        lpep_pickup_datetime TIMESTAMP,
        ...
    )
    PARTITION BY DATE(lpep_pickup_datetime)
```

**BigQuery Features:**
- Native partitioning by date
- Automatic schema management
- No need for Iceberg (BigQuery handles ACID natively)

#### 4. Create External Table

```yaml
- id: bq_green_table_ext
  type: io.kestra.plugin.gcp.bigquery.Query
  sql: |
    CREATE OR REPLACE EXTERNAL TABLE `{{kv('GCP_PROJECT_ID')}}.{{render(vars.table)}}_ext`
    (...)
    OPTIONS (
        format = 'CSV',
        uris = ['{{render(vars.gcs_file)}}'],
        skip_leading_rows = 1,
        ignore_unknown_values = TRUE
    )
```

**Note:** BigQuery supports `CREATE OR REPLACE` natively.

#### 5. Create Temporary Table

```yaml
- id: bq_green_table_tmp
  type: io.kestra.plugin.gcp.bigquery.Query
  sql: |
    CREATE OR REPLACE TABLE `{{kv('GCP_PROJECT_ID')}}.{{render(vars.table)}}`
    AS
    SELECT
      MD5(CONCAT(
        COALESCE(CAST(VendorID AS STRING), ""),
        COALESCE(CAST(lpep_pickup_datetime AS STRING), ""),
        ...
      )) AS unique_row_id,
      "{{render(vars.file)}}" AS filename,
      *
    FROM `{{kv('GCP_PROJECT_ID')}}.{{render(vars.table)}}_ext`
```

**BigQuery Syntax Differences:**
- `MD5()` instead of `to_hex(md5(to_utf8()))`
- `STRING` instead of `varchar`
- Double quotes for strings
- Backticks for table names

#### 6. Merge into Final Table

```yaml
- id: bq_green_merge
  type: io.kestra.plugin.gcp.bigquery.Query
  sql: |
    MERGE INTO `{{kv('GCP_PROJECT_ID')}}.{{kv('GCP_DATASET')}}.green_tripdata` T
    USING `{{kv('GCP_PROJECT_ID')}}.{{render(vars.table)}}` S
    ON T.unique_row_id = S.unique_row_id
    WHEN NOT MATCHED THEN
      INSERT (...)
      VALUES (...)
```

### GCP Services Used

| Service | Purpose |
|---------|---------|
| **Cloud Storage (GCS)** | Object storage for raw CSVs |
| **BigQuery** | Serverless data warehouse |
| **BigQuery External Tables** | Query data directly in GCS |

### Plugin Defaults

```yaml
pluginDefaults:
  - type: io.kestra.plugin.gcp
    values:
      serviceAccount: "{{kv('GCP_CREDS')}}"
      projectId: "{{kv('GCP_PROJECT_ID')}}"
      location: "{{kv('GCP_LOCATION')}}"
      bucket: "{{kv('GCP_BUCKET_NAME')}}"
```

This eliminates credential repetition across tasks.

---

## End-to-End Flow

### Execution Order

```
1. INFRASTRUCTURE (One-time setup)
   └── terraform init
   └── terraform apply
       ├── Creates S3 buckets
       ├── Creates Athena database
       └── Creates Athena workgroup

2. CONFIGURATION (One-time setup)
   └── Kestra KV Store
       ├── AWS_ACCESS_KEY
       ├── AWS_SECRET_KEY
       ├── AWS_REGION
       ├── S3_DATA_LAKE_BUCKET
       ├── ATHENA_DATABASE
       ├── ATHENA_OUTPUT_LOCATION
       └── GEMINI_API_KEY (optional)

3. WORKFLOW EXECUTION (Per month)
   └── Kestra UI: Execute with inputs
       ├── taxi: green/yellow
       ├── year: 2019/2020/2021
       └── month: 01-12

4. DATA FLOW
   GitHub (CSV.gz)
       │
       ▼
   Kestra (Extract + Decompress)
       │
       ▼
   S3/GCS (Raw CSV)
       │
       ▼
   Athena/BigQuery (External Table)
       │
       ▼
   Athena/BigQuery (Temp Table + Dedup)
       │
       ▼
   Athena/BigQuery (MERGE → Final Table)
       │
       ▼
   Cleanup (Drop temp tables)
```

### Data Lineage

| Stage | AWS | GCP |
|-------|-----|-----|
| Raw Storage | `s3://bucket/green_tripdata/year=2019/month=01/` | `gs://bucket/green_tripdata_2019-01.csv` |
| External Table | `green_tripdata_2019_01_ext` | `dataset.green_tripdata_2019_01_ext` |
| Temp Table | `green_tripdata_2019_01_tmp` | `dataset.green_tripdata_2019_01` |
| Final Table | `green_tripdata` (Iceberg) | `dataset.green_tripdata` (Partitioned) |

---

## How to Run

### Prerequisites

- **Terraform** >= 1.0
- **Docker** (for Kestra)
- **AWS Account** with admin access
- **GCP Project** with BigQuery and GCS enabled (for GCP flow)
- **Kestra** instance (local or cloud)

.dataset.green_tripdata`;
SELECT * FROM `project.dataset.green_tripdata` LIMIT 10;
```

### 8. Cleanup

```bash
# Destroy AWS infrastructure
cd terraform
terraform destroy

# Stop Kestra
docker-compose down
```

---

## Best Practices & Notes

### Security Considerations

1. **Credentials Management**
   - Store credentials in Kestra KV Store, not in workflow files
   - Use IAM roles with least-privilege access
   - Rotate access keys regularly

2. **S3 Bucket Security**
   - Enable versioning (already configured in Terraform)
   - Consider enabling server-side encryption
   - Use bucket policies to restrict access

3. **Network Security**
   - Run Kestra in a private subnet if possible
   - Use VPC endpoints for S3 and Athena

### Cost Considerations

| Service | Cost Driver | Optimization |
|---------|-------------|--------------|
| **S3** | Storage volume | Use lifecycle policies to archive old data |
| **Athena** | Data scanned | Use partitioning and Parquet format |
| **BigQuery** | Data scanned | Use partitioning and clustering |
| **Kestra** | Compute time | Use appropriate container sizes |

**Estimated Monthly Cost (AWS):**
- S3: ~$0.023/GB stored
- Athena: ~$5/TB scanned
- Total for 10GB data: < $5/month

### Scalability & Extensibility

1. **Adding New Data Sources**
   - Create new workflow files following the same pattern
   - Reuse the extract/load/transform structure

2. **Scheduling**
   ```yaml
   triggers:
     - id: monthly_schedule
       type: io.kestra.plugin.core.trigger.Schedule
       cron: "0 0 1 * *"  # First day of each month
       timezone: America/New_York
   ```

3. **Backfilling Historical Data**
   ```yaml
   triggers:
     - id: backfill
       type: io.kestra.plugin.core.trigger.Flow
       inputs:
         taxi: green
         year: "{{range(2019, 2022)}}"
         month: "{{range(1, 13)}}"
   ```

4. **Error Handling**
   ```yaml
   errors:
     - id: send_alert
       type: io.kestra.plugin.notifications.slack.SlackIncomingWebhook
       url: "{{kv('SLACK_WEBHOOK')}}"
       payload: |
         {"text": "Pipeline failed: {{flow.id}}"}
   ```

### Known Limitations

1. **Athena MERGE** requires Iceberg tables (not supported on standard Hive tables)
2. **External tables** must point to directories, not individual files
3. **CSV parsing** may fail on malformed rows - use `ignore_unknown_values` in BigQuery
4. **Rate limits** may apply for large batch operations

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---


## Acknowledgments

- [DataTalksClub](https://github.com/DataTalksClub) for the NYC taxi data
- [Kestra](https://kestra.io/) for the orchestration platform
- [Data Engineering Zoomcamp](https://github.com/DataTalksClub/data-engineering-zoomcamp) for the inspiration