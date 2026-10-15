#!/bin/bash
# Usage: wait-ssm.sh <command-id> <instance-id> <region>

COMMAND_ID=$1
INSTANCE_ID=$2
AWS_REGION=$3
RETRIES=0

echo "============================================"
echo "Waiting for SSM Command: $COMMAND_ID"
echo "Instance: $INSTANCE_ID"
echo "Region: $AWS_REGION"
echo "============================================"

while true; do
  RETRIES=$((RETRIES + 1))

  if [[ $RETRIES -gt 40 ]]; then
    echo "ERROR: SSM command timed out after 40 attempts"
    exit 1
  fi

  sleep 15

  RESULT=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --output json 2>&1)

  if echo "$RESULT" | grep -q "InvocationDoesNotExist"; then
    echo "Attempt $RETRIES: Invocation not yet registered, retrying..."
    continue
  fi

  STATUS=$(echo "$RESULT" | jq -r '.Status // "Unknown"')
  STDOUT=$(echo "$RESULT" | jq -r '.StandardOutputContent // ""')
  STDERR=$(echo "$RESULT" | jq -r '.StandardErrorContent // ""')

  echo "============================================"
  echo "Attempt $RETRIES — Status: $STATUS"
  echo "============================================"

  if [[ -n "$STDOUT" ]]; then
    echo "--- STDOUT ---"
    echo "$STDOUT"
    echo "--------------"
  fi

  if [[ -n "$STDERR" ]]; then
    echo "--- STDERR ---"
    echo "$STDERR"
    echo "--------------"
  fi

  if [[ "$STATUS" == "Success" ]]; then
    echo "SSM Command completed successfully"
    exit 0
  elif [[ "$STATUS" == "Failed" || "$STATUS" == "Cancelled" || "$STATUS" == "TimedOut" ]]; then
    echo "SSM Command $STATUS"
    echo "STDERR: $STDERR"
    exit 1
  else
    echo "Status=$STATUS — checking again in 15s..."
  fi
done
