# DB Foundry Changelog Repository

This is the changelog repository for DB Foundry. The DB Foundry UI (AR-db-foundry-ui)
generates liquibase changeset files and pushes them here. GitHub Actions workflows
then validate and deploy those changesets to target databases via Liquibase running
on an EC2 instance (accessed through AWS SSM).

## Architecture Overview

```
DB Foundry UI  ──push changeset──▶  This Repo (changelog)
                                         │
                                    PR raised ──▶ pr_validate.yml  ──▶ liquibase validate
                                         │
                                    PR merged ──▶ deploy.yml       ──▶ liquibase validate + update
                                         │
                                         ▼
                                    EC2 via SSM
                                    (ASG scales 0→1→0)
```


## Repository Structure

```
.
├── .github/
│   ├── workflows/
│   │   ├── pr_validate.yml     # PR trigger → liquibase validate
│   │   └── deploy.yml          # Push-to-master trigger → validate + update
│   └── scripts/
│       └── wait-ssm.sh         # Helper: poll SSM command until completion
├── configs/
│   ├── MySQL.properties        # Connection template for SQL databases
│   └── MongoDB.properties      # Connection template for MongoDB databases
├── dbs/                        # Same layout as SHL-India/AM-db-migration-service
│   ├── dev|qa|stg|uat/
│   │   ├── sql/<db-name>/
│   │   │   ├── changelog-master.xml          # includeAll path="changeset" — never edit
│   │   │   └── changeset/*.sql
│   │   └── MongoDB/<db-name>/                # note the capital M, D, B
│   │       ├── changelog-master.xml
│   │       └── changeset/*.yml
│   ├── stg-rollback|uat-rollback/            # Rollback changesets, same layout
│   └── prod/
│       ├── AU|EU|US|CH/                      # Region-based; same layout as above
│       └── AU-rollback|EU-rollback|US-rollback|CH-rollback/
├── run-liquibase.sh            # Main runner: discovers DBs, runs liquibase with each DB's changelog-master.xml
└── CLAUDE.md                   # This file
```

### Changeset file formats

**SQL** (`dbs/<env>/sql/<db-name>/changeset/V<version>_<jira>_<desc>.sql`):
```sql
--liquibase formatted sql

--changeset author:V0.01.01:JIRA-1234:description labels:pre context:db-name
--comment: JIRA-1234:summary of change

ALTER TABLE users ADD COLUMN active BOOLEAN DEFAULT TRUE;
```

**MongoDB** (`dbs/<env>/MongoDB/<db-name>/changeset/V<version>_<jira>_<desc>.yml`):
```yaml
databaseChangeLog:
- changeSet:
      id: V0.01.01:JIRA-1234:description
      author: user.name
      context: db-name
      labels: pre
      comment: JIRA-1234:summary
      changes:
        - runCommand:
            command: |
              { "create": "collectionName" }
```

## Workflow Details

### PR Validate (`pr_validate.yml`)

- **Triggers**:
  - `pull_request` to `master` (opened, synchronize, reopened)
  - `merge_group` — runs when PR enters the GitHub Merge Queue (pre-merge check)
  - `workflow_dispatch` for manual runs
- **What it does**: Runs `liquibase validate` to check changeset syntax
- **Environment detection**: Auto-detects from changed file paths (`dbs/<env>/...`). `*-rollback` folders are ignored for detection (a PR touching only rollback files skips validate)
- **Constraint**: A single PR must only touch one environment
- **Posts**: GitHub commit status (`liquibase-validate`) on the PR

### Deploy (`deploy.yml`)

- **Trigger**: `push` to `master` (i.e., after PR is merged) + manual `workflow_dispatch`
- **What it does**:
  - Job 1 (`validate`): Scales up EC2, runs `liquibase validate`
  - Job 2 (`update`): Scales up EC2 again, runs `liquibase update` to apply changesets
- **Environment detection**: Same as PR validate — from changed files in the merge commit

### Concurrency / Queuing

The shared EC2/ASG can only handle one liquibase run at a time. Each workflow
uses a different strategy suited to its needs:

**PR Validate** — uses two complementary mechanisms:

1. **GitHub Merge Queue** (`merge_group` trigger): When enabled on the repo,
   the merge queue sends one PR at a time for pre-merge checks. This serializes
   EC2 access across different PRs — no collisions, no wasted runners.
2. **Per-PR concurrency group** (`cancel-in-progress: true`): If a new push
   arrives on the same PR, the stale validate run is cancelled immediately
   (the old code is outdated anyway). Different PRs get different groups so
   they never cancel each other.

**Deploy** — uses a custom **FIFO polling queue**:

- The first step polls the GitHub API for older deploy runs that are still
  `in_progress`, `queued`, or `waiting`
- It waits (up to 1 hour) until all older runs finish, then proceeds
- No deploy is ever cancelled — every merge is guaranteed to be deployed
- The queue script is at `.github/scripts/wait-for-queue.sh` (reference
  implementation) and is also inlined in the workflow

### GitHub Merge Queue Setup

To enable the merge queue on this repository:

1. Go to **Settings → Rules → Rulesets** (or Branch protection rules)
2. For the `master` branch, enable **Require merge queue**
3. Under merge queue settings:
   - Set **Maximum pull requests to build** = `1` (sequential)
   - Set **Required status checks** = `PR Validate` (the workflow name)
4. PRs can no longer be merged directly — they must go through the queue

When a reviewer approves a PR and clicks "Merge", the PR enters the queue.
The merge queue creates a temporary branch, runs `PR Validate`, and if it
passes, auto-merges to `master` (which then triggers the `Deploy` workflow).

### Execution flow (both workflows)

1. Detect environment from changed file paths
2. Load AWS config (role, region, ASG, AppConfig) for that environment
3. Assume AWS role via OIDC
4. Scale up ASG (0 → 1) to start EC2 instance
5. Wait for EC2 + SSM agent to be ready
6. Fetch `liquibase.env` and `versions.json` from AWS AppConfig
7. Clone this repo onto EC2 via SSM
8. Install Java + Liquibase + DB drivers on EC2
9. Run `liquibase validate` (and `update` for deploy workflow)
10. Scale down ASG (1 → 0) — always runs, even on failure

### `run-liquibase.sh`

The runner script discovers databases automatically:
1. Scans `dbs/<env>/sql/` and `dbs/<env>/MongoDB/` for DB directories (prod: `dbs/prod/<REGION>/...`)
2. For each DB, uses the committed `changelog-master.xml` (`<includeAll path="changeset"/>`) with `--searchPath` set to the DB folder. Rollback trees (`*-rollback`) are never run by this script
3. Reads DB credentials from `env/liquibase.env` (env var naming convention: `<DB_NAME_UPPER>_DB_HOST`, `_DB_NAME`, `_DB_USERNAME`, `_DB_PASSWORD`)
4. Generates a runtime `.properties` file from the config template
5. Runs the requested liquibase command

## Setup Guide — What You Need to Configure (GENERATED BY CLAUDE, I am not sure of the exact settings)

### 1. GitHub Repository Secrets

Go to **Settings → Secrets and variables → Actions** on this repository and add:

| Secret Name | Description | Example |
|------------|-------------|---------|
| `GH_PAT` | GitHub Personal Access Token with `repo` scope (for cloning this repo onto EC2 via SSM) | `ghp_xxxxxxxxxxxx` |
| `ASG_NAME` | Auto Scaling Group name for the liquibase runner EC2 | `db-migration-runner-asg` |
| `AWS_ROLE_ARN_TCP_DEV` | IAM role ARN for dev environment (OIDC) | `arn:aws:iam::role/...` |
| `AWS_ROLE_ARN_TCP_QA` | IAM role ARN for qa environment (OIDC) | `arn:aws:iam::role/...` |
| `AWS_ROLE_ARN_TCP_STG` | IAM role ARN for stg environment (OIDC) | `arn:aws:iam::role/...` |
| `AWS_ROLE_ARN_TCP_UAT` | IAM role ARN for uat environment (OIDC) | `arn:aws:iam::role/...` |
| `AWS_ROLE_ARN_TCP_PROD` | IAM role ARN for prod environment (OIDC) | `arn:aws:iam::role/...` |

These are the same secrets used in the AM-db-migration-service repository.

### 2. AWS IAM — OIDC Trust Policy

### 3. AWS AppConfig


#### `liquibase-env` (DB credentials)

A key-value file with connection details for each database. Naming convention — for a DB directory named `catalog-db`, use prefix `CATALOG_DB_` (uppercase, hyphens → underscores):

```env
ALLOWED_DATABASES=catalog-db,user-db

CATALOG_DB_DB_HOST=myhost.rds.amazonaws.com
CATALOG_DB_DB_NAME=catalog
CATALOG_DB_DB_USERNAME=admin
CATALOG_DB_DB_PASSWORD=secretpass
CATALOG_DB_DB_TYPE=MySQL

USER_DB_DB_HOST=myhost.rds.amazonaws.com
USER_DB_DB_NAME=userdb
USER_DB_DB_USERNAME=admin
USER_DB_DB_PASSWORD=secretpass
USER_DB_DB_TYPE=MySQL
```

> Note: `ALLOWED_DATABASES` is not used by this repo's `run-liquibase.sh` (it auto-discovers from the directory structure), but can be kept for compatibility.

#### `liquibase-versions` (tool versions)

A JSON file specifying which versions of Liquibase and drivers to install:

```json
{
  "LB_VERSION": "4.29.2",
  "MYSQL_DRIVER_VERSION": "8.0.33",
  "MONGO_EXT_VERSION": "4.29.0",
  "MONGO_DRIVER_VERSION": "4.11.1"
}
```

#### AppConfig application/environment mapping

| Env | AppConfig Application | AppConfig Environment |
|-----|----------------------|----------------------|
| dev | `tcplusdev-db-migration-github` | `dev` |
| qa  | `tcplusdev-db-migration-github` | `qa` |
| stg | `tcplusstg-db-migration` | `stg` |
| uat | `tcp-uat-db-migration` | `uat` |
| prod US | `tcp-us-prod-db-migration` | `us` |
| prod EU | `tcp-eu-prod-db-migration` | `eu` |
| prod AU | `tcp-au-prod-db-migration` | `au` |
| prod CH | `tcp-ch-prod-db-migration` | `ch` |

### 4. EC2 / ASG Requirements

The ASG must:
- Be in the same AWS account and region as the target databases
- Have SSM agent installed on the AMI
- Have outbound internet access (to clone the repo and download Liquibase)
- Have network access to the target databases (RDS, MongoDB)

The ASG normally sits at desired capacity 0. The workflow scales it to 1, runs the job, then scales back to 0.

### 5. GitHub Actions Permissions

The repository must have GitHub Actions enabled with:
- **Workflow permissions**: Read and write (for posting commit statuses)
- **OIDC**: Allow `id-token: write` (for AWS OIDC authentication)

## Related Repositories

| Repository | Purpose |
|-----------|---------|
| `AR-db-foundry-ui` | Frontend — the DB Foundry web interface |
| `AR-db-foundry-backend` | Backend — API server, GitHub integration, changeset generation |
| `AM-db-migration-service` | Original migration service (this repo's workflows are based on it) |
