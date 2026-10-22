#!/bin/bash
set -euo pipefail

# =============================================================================
# run-liquibase.sh — DB Foundry changelog runner
#
# Discovers all databases under dbs/<env>/ and runs the given liquibase command
# against each one. Unlike AM-db-migration-service (which uses pre-written
# changelog-master.xml files), this script auto-generates a temporary master
# changelog per DB using <includeAll> to pick up every script in scripts/.
#
# NOTE: this repo now mirrors AM-db-migration-service's layout, so each DB has
# a committed changelog-master.xml (includeAll path="changeset") next to its
# changeset/ folder, and Mongo DBs live under "MongoDB/". The runner below uses
# that committed master instead of generating a temp one.
#
# Usage:  run-liquibase.sh <env> <command> [region]
#   env     : dev | qa | stg | uat | prod
#   command : validate | update | status | rollbackCount | ...
#   region  : US | EU | AU | CH  (required for prod, ignored otherwise)
#
# Expects:
#   - env/liquibase.env   : DB credentials (fetched from AWS AppConfig)
#   - configs/MySQL.properties   : connection template for SQL databases
#   - configs/MongoDB.properties : connection template for MongoDB databases
# =============================================================================

LIQUIBASE_BIN=liquibase
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENVIRONMENT="${1}"
COMMAND="${2}"
REGION="${3:-none}"

LOG_LEVEL="${LOG_LEVEL:-INFO}"

log_error() {
  printf '\033[1;31m%s\033[0m\n' "$1" >&2
}

# ── Validate inputs ─────────────────────────────────────────────────────────

ALLOWED_ENVS=("dev" "qa" "stg" "uat" "prod")
ALLOWED_REGIONS=("US" "EU" "AU" "CH")

validate_env() {
  for e in "${ALLOWED_ENVS[@]}"; do
    [[ "$e" == "$ENVIRONMENT" ]] && return 0
  done
  return 1
}

validate_region() {
  for r in "${ALLOWED_REGIONS[@]}"; do
    [[ "$r" == "$1" ]] && return 0
  done
  return 1
}

if ! validate_env; then
  log_error "ERROR: Invalid ENVIRONMENT '$ENVIRONMENT'. Allowed: ${ALLOWED_ENVS[*]}"
  exit 1
fi

if [[ "$ENVIRONMENT" == "prod" ]]; then
  if [[ "$REGION" == "none" || -z "$REGION" ]]; then
    log_error "ERROR: Region is required when ENVIRONMENT=prod. Allowed: ${ALLOWED_REGIONS[*]}"
    exit 1
  fi
  if ! validate_region "$REGION"; then
    log_error "ERROR: Invalid Region '$REGION'. Allowed: ${ALLOWED_REGIONS[*]}"
    exit 1
  fi
fi

# ── Load environment file ───────────────────────────────────────────────────

ENV_FILE="$BASE_DIR/env/liquibase.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log_error "ERROR: Environment file not found: $ENV_FILE"
  exit 1
fi
sed -i 's/\r$//' "$ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# ── Resolve DB base path ────────────────────────────────────────────────────

if [[ "$ENVIRONMENT" == "prod" ]]; then
  DB_BASE="$BASE_DIR/dbs/prod/$REGION"
else
  DB_BASE="$BASE_DIR/dbs/$ENVIRONMENT"
fi

if [[ ! -d "$DB_BASE" ]]; then
  log_error "ERROR: DB directory not found: $DB_BASE"
  exit 1
fi

# ── Helper: get env var value by name ────────────────────────────────────────

getvar() { printf '%s' "${!1-}"; }

# ── Discover and process databases ───────────────────────────────────────────

PROCESSED=0
ERRORS=0

process_db() {
  local db_type="$1"   # sql or MongoDB
  local db_name="$2"   # e.g. catalog-db, user-db
  local db_dir="$3"    # full path to the DB directory
  local scripts_dir="$db_dir/changeset"
  local master="$db_dir/changelog-master.xml"

  if [[ ! -d "$scripts_dir" ]]; then
    echo "SKIP: No changeset/ directory in $db_dir"
    return
  fi
  if [[ ! -f "$master" ]]; then
    log_error "ERROR: changelog-master.xml not found: $master"
    ERRORS=$((ERRORS + 1))
    return
  fi

  local script_count
  if [[ "$db_type" == "sql" ]]; then
    script_count=$(find "$scripts_dir" -maxdepth 1 -name '*.sql' -not -name 'changelog-master-*' | wc -l)
  else
    script_count=$(find "$scripts_dir" -maxdepth 1 \( -name '*.yaml' -o -name '*.yml' -o -name '*.xml' -o -name '*.json' \) -not -name 'changelog-master-*' | wc -l)
  fi

  if [[ "$script_count" -eq 0 ]]; then
    echo "SKIP: No changeset files in $scripts_dir"
    return
  fi

  # Resolve DB credentials from env vars
  # Convention: env var prefix = DB_NAME uppercased with hyphens replaced by underscores
  local upper_prefix
  upper_prefix="$(echo "$db_name" | tr '[:lower:]-' '[:upper:]_')"

  local DB_HOST DB_NAME_VAL DB_USER DB_PASS
  DB_HOST="$(getvar "${upper_prefix}_DB_HOST")"
  DB_NAME_VAL="$(getvar "${upper_prefix}_DB_NAME")"
  DB_USER="$(getvar "${upper_prefix}_DB_USERNAME")"
  DB_PASS="$(getvar "${upper_prefix}_DB_PASSWORD")"

  local missing=()
  [[ -z "$DB_HOST" ]]     && missing+=("${upper_prefix}_DB_HOST")
  [[ -z "$DB_NAME_VAL" ]] && missing+=("${upper_prefix}_DB_NAME")
  [[ -z "$DB_USER" ]]     && missing+=("${upper_prefix}_DB_USERNAME")
  [[ -z "$DB_PASS" ]]     && missing+=("${upper_prefix}_DB_PASSWORD")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "ERROR: Missing env vars for $db_name: ${missing[*]}"
    ERRORS=$((ERRORS + 1))
    return
  fi

  # Select config template
  local config_template
  if [[ "$db_type" == "sql" ]]; then
    config_template="$BASE_DIR/configs/MySQL.properties"
  else
    config_template="$BASE_DIR/configs/MongoDB.properties"
  fi

  if [[ ! -f "$config_template" ]]; then
    log_error "ERROR: Config template not found: $config_template"
    ERRORS=$((ERRORS + 1))
    return
  fi

  # Generate runtime config with substituted values
  export DB_HOST DB_USERNAME="$DB_USER" DB_PASSWORD="$DB_PASS" DB_NAME="$DB_NAME_VAL"
  local runtime_config="$BASE_DIR/configs/${db_name}.runtime.properties"
  envsubst < "$config_template" > "$runtime_config"

  local changelog_name
  changelog_name=$(basename "$master")

  echo ""
  echo -e "\033[0;32m==========================================================================\033[0m"
  echo "## DB           : $DB_NAME_VAL ($db_type)"
  echo "## DB Host      : $DB_HOST"
  echo "## Environment  : $ENVIRONMENT"
  echo "## Region       : ${REGION}"
  echo "## Scripts Dir  : $scripts_dir"
  echo "## Script Count : $script_count"
  echo "## Command      : $COMMAND"
  echo -e "\033[0;32m==========================================================================\033[0m"

  local CMD=(
    "$LIQUIBASE_BIN"
    "--defaultsFile=$runtime_config"
    "--searchPath=${db_dir%/}"
    "--changeLogFile=$changelog_name"
    "--log-level=$LOG_LEVEL"
    "$COMMAND"
  )

  echo "## Executing: ${CMD[*]}"
  echo ""

  if "${CMD[@]}"; then
    echo "Liquibase $COMMAND completed for $db_name"
    PROCESSED=$((PROCESSED + 1))
  else
    log_error "ERROR: Liquibase $COMMAND FAILED for $db_name"
    ERRORS=$((ERRORS + 1))
  fi

  # Cleanup temp files
  rm -f "$runtime_config"
}

# ── Iterate over sql/ and MongoDB/ directories ──────────────────────────────

for db_type_dir in "$DB_BASE"/sql "$DB_BASE"/MongoDB; do
  [[ ! -d "$db_type_dir" ]] && continue

  db_type=$(basename "$db_type_dir")

  for db_dir in "$db_type_dir"/*/; do
    [[ ! -d "$db_dir" ]] && continue
    db_name=$(basename "$db_dir")
    process_db "$db_type" "$db_name" "$db_dir"
  done
done

echo ""
echo -e "\033[0;32m==========================================================================\033[0m"
echo "Liquibase execution complete. Processed: $PROCESSED | Errors: $ERRORS"
echo -e "\033[0;32m==========================================================================\033[0m"

if [[ $ERRORS -gt 0 ]]; then
  exit 1
fi

if [[ $PROCESSED -eq 0 ]]; then
  echo "WARNING: No databases were processed. Check that dbs/$ENVIRONMENT/ has sql/ or MongoDB/ subdirectories with changeset/ folders."
fi
