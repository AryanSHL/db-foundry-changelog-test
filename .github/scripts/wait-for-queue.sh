#!/bin/bash
# =============================================================================
# wait-for-queue.sh — True FIFO queue for GitHub Actions workflows
#
# GitHub Actions concurrency groups only keep 1 running + 1 pending.
# A 3rd event replaces the pending one (effectively cancelled).
# This script implements true queuing: it polls the GitHub API and waits
# until all older runs of the SAME workflow have completed before proceeding.
#
# Usage: wait-for-queue.sh <repo> <workflow-file> <current-run-id> <token>
#
# Example:
#   bash .github/scripts/wait-for-queue.sh \
#     "AryanSHL/db-foundry-changelog-test" "deploy.yml" "$GITHUB_RUN_ID" "$GITHUB_TOKEN"
# =============================================================================

REPO="$1"
WORKFLOW_FILE="$2"
CURRENT_RUN_ID="$3"
GH_TOKEN="$4"

MAX_WAIT=3600    # 1 hour max wait
POLL_INTERVAL=30 # check every 30 seconds
ELAPSED=0

echo "============================================"
echo "Queue: waiting for older runs to complete"
echo "Repo: $REPO"
echo "Workflow: $WORKFLOW_FILE"
echo "Current Run ID: $CURRENT_RUN_ID"
echo "============================================"

while true; do
  # Fetch all in_progress or queued runs for this workflow
  RESPONSE=$(curl -s \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?status=in_progress&per_page=100")

  # Count runs with a lower run_id (older) that are still running
  OLDER_RUNNING=$(echo "$RESPONSE" | jq "[.workflow_runs[] | select(.id < $CURRENT_RUN_ID)] | length")

  # Also check queued/waiting runs
  RESPONSE_QUEUED=$(curl -s \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?status=queued&per_page=100")

  OLDER_QUEUED=$(echo "$RESPONSE_QUEUED" | jq "[.workflow_runs[] | select(.id < $CURRENT_RUN_ID)] | length")

  # Also check waiting runs
  RESPONSE_WAITING=$(curl -s \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?status=waiting&per_page=100")

  OLDER_WAITING=$(echo "$RESPONSE_WAITING" | jq "[.workflow_runs[] | select(.id < $CURRENT_RUN_ID)] | length")

  TOTAL_AHEAD=$((OLDER_RUNNING + OLDER_QUEUED + OLDER_WAITING))

  if [[ "$TOTAL_AHEAD" -eq 0 ]]; then
    echo "No older runs ahead — proceeding."
    exit 0
  fi

  if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    echo "ERROR: Timed out after ${MAX_WAIT}s waiting in queue."
    echo "There are still $TOTAL_AHEAD older run(s) ahead."
    exit 1
  fi

  echo "Queue position: $TOTAL_AHEAD run(s) ahead (running=$OLDER_RUNNING, queued=$OLDER_QUEUED, waiting=$OLDER_WAITING). Waiting ${POLL_INTERVAL}s... ($ELAPSED/${MAX_WAIT}s)"
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
