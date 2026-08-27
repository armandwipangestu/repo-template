#!/bin/sh
# =============================================================================
# GitLab MR Auto-Labeler
# Mirrors: .github/labeler.yml
# =============================================================================
# This script automatically applies labels to Merge Requests based on changed files,
# replicating the behavior of actions/labeler@v6 from GitHub Actions.
# =============================================================================

set -e

# Configuration
PROJECT_ID="${CI_PROJECT_ID}"
MR_IID="${CI_MERGE_REQUEST_IID}"
API_URL="${CI_API_V4_URL}"
TOKEN="${GITLAB_TOKEN}"

MISSING=""
[ -z "$PROJECT_ID" ] && MISSING="${MISSING} CI_PROJECT_ID"
[ -z "$MR_IID" ] && MISSING="${MISSING} CI_MERGE_REQUEST_IID"
[ -z "$TOKEN" ] && MISSING="${MISSING} GITLAB_TOKEN (set GL_ACCESS_TOKEN in CI/CD variables)"

if [ -n "$MISSING" ]; then
  echo "Error: Missing required variables:${MISSING}"
  exit 1
fi

echo "Labeler: Processing MR !${MR_IID} in project ${PROJECT_ID}"

# Get list of changed files in the MR
CHANGED_FILES=$(curl --silent --header "PRIVATE-TOKEN: ${TOKEN}" \
  "${API_URL}/projects/${PROJECT_ID}/merge_requests/${MR_IID}/changes" | \
  jq -r '.changes[].new_path // empty' 2>/dev/null || echo "")

if [ -z "$CHANGED_FILES" ]; then
  echo "Labeler: No changed files detected or API error."
  exit 0
fi

echo "Labeler: Changed files:"
echo "$CHANGED_FILES"

# Get current labels on the MR (comma-separated)
CURRENT_LABELS=$(curl --silent --header "PRIVATE-TOKEN: ${TOKEN}" \
  "${API_URL}/projects/${PROJECT_ID}/merge_requests/${MR_IID}" | \
  jq -r '.labels | join(",")' 2>/dev/null || echo "")

echo "Labeler: Current labels: '${CURRENT_LABELS}'"

# Label definitions (mirrors .github/labeler.yml)
LABELS_TO_ADD=""

# --- check_chore: CHANGELOG.md, .gitignore, .prettierrc, package.json, bun.lock ---
check_chore() {
  for f in $CHANGED_FILES; do
    case "$f" in
      CHANGELOG.md|.gitignore|.prettierrc|package.json|bun.lock) return 0 ;;
    esac
  done
  return 1
}

# --- check_ci: .gitlab-ci.yml, .gitlab/** ---
check_ci() {
  for f in $CHANGED_FILES; do
    case "$f" in
      .gitlab-ci.yml|.gitlab/*) return 0 ;;
    esac
  done
  return 1
}

# --- check_documentation: README.md, docs/** ---
check_documentation() {
  for f in $CHANGED_FILES; do
    case "$f" in
      README.md|docs/*) return 0 ;;
    esac
  done
  return 1
}

# --- check_feature: src/**, app/**, components/** ---
check_feature() {
  for f in $CHANGED_FILES; do
    case "$f" in
      src/*|app/*|components/*) return 0 ;;
    esac
  done
  return 1
}

# --- check_content: content/** ---
check_content() {
  for f in $CHANGED_FILES; do
    case "$f" in
      content/*) return 0 ;;
    esac
  done
  return 1
}

# --- check_config: *.config.*, tsconfig.json, components.json, .env.example ---
check_config() {
  for f in $CHANGED_FILES; do
    case "$f" in
      *.config.*|tsconfig.json|components.json|.env.example) return 0 ;;
    esac
  done
  return 1
}

# Check each label and build comma-separated list
has_label() {
  case ",$CURRENT_LABELS," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

add_label() {
  has_label "$1" && return
  if [ -n "$LABELS_TO_ADD" ]; then
    LABELS_TO_ADD="${LABELS_TO_ADD},${1}"
  else
    LABELS_TO_ADD="$1"
  fi
  echo "Labeler: Will add label '${1}'"
}

check_chore && add_label "chore"
check_ci && add_label "ci"
check_documentation && add_label "documentation"
check_feature && add_label "feature"
check_content && add_label "content"
check_config && add_label "config"

# Apply labels via API
if [ -n "$LABELS_TO_ADD" ]; then
  if [ -n "$CURRENT_LABELS" ]; then
    ALL_LABELS="${CURRENT_LABELS},${LABELS_TO_ADD}"
  else
    ALL_LABELS="${LABELS_TO_ADD}"
  fi

  curl --silent --request PUT \
    --header "PRIVATE-TOKEN: ${TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{\"labels\": \"${ALL_LABELS}\"}" \
    "${API_URL}/projects/${PROJECT_ID}/merge_requests/${MR_IID}" > /dev/null

  echo "Labeler: Successfully updated labels to '${ALL_LABELS}'"
else
  echo "Labeler: No new labels to add"
fi
