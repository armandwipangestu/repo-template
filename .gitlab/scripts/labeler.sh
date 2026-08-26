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

if [ -z "$PROJECT_ID" ] || [ -z "$MR_IID" ] || [ -z "$TOKEN" ]; then
  echo "Error: Missing required environment variables (CI_PROJECT_ID, CI_MERGE_REQUEST_IID, GITLAB_TOKEN)"
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

# Get current labels on the MR
CURRENT_LABELS=$(curl --silent --header "PRIVATE-TOKEN: ${TOKEN}" \
  "${API_URL}/projects/${PROJECT_ID}/merge_requests/${MR_IID}" | \
  jq -r '.labels[]' 2>/dev/null || echo "")

# Label definitions (mirrors .github/labeler.yml)
# Format: label_name|glob_patterns (pipe-separated)
LABEL_RULES="
chore|CHANGELOG.md:.gitignore:.prettierrc:package.json:bun.lock
ci|.gitlab-ci.yml:.gitlab/**
documentation|README.md:docs/**
feature|src/**:app/**:components/**
content|content/**
config|*.config.*:tsconfig.json:components.json:.env.example
"

# Function to check if a file matches a glob pattern
matches_pattern() {
  file="$1"
  pattern="$2"

  # Handle ** (recursive) patterns
  case "$pattern" in
    **)
      prefix="${pattern%%\*\*}"
      prefix="${prefix%\/}"
      if [ -n "$prefix" ]; then
        case "$file" in
          ${prefix}*) return 0 ;;
        esac
      fi
      ;;
    *)
      # Exact match or simple wildcard
      case "$file" in
        $pattern) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Determine which labels to apply
LABELS_TO_ADD=""

echo "$LABEL_RULES" | while IFS='|' read -r label patterns; do
  # Skip empty lines
  [ -z "$label" ] && continue

  # Trim whitespace
  label=$(echo "$label" | xargs)
  patterns=$(echo "$patterns" | xargs)

  # Check if any changed file matches any pattern for this label
  apply_label=false

  OLD_IFS="$IFS"
  IFS=':'
  for pattern in $patterns; do
    pattern=$(echo "$pattern" | xargs)
    [ -z "$pattern" ] && continue

    echo "$CHANGED_FILES" | while IFS= read -r file; do
      [ -z "$file" ] && continue

      # Check for ** patterns (recursive directory)
      case "$pattern" in
        **)
          prefix="${pattern%%\*\*}"
          prefix="${prefix%\/}"
          suffix="${pattern##*\*\*}"
          suffix="${suffix#\/}"

          if [ -n "$prefix" ] && [ -n "$suffix" ]; then
            case "$file" in
              ${prefix}*${suffix}) apply_label=true; break ;;
            esac
          elif [ -n "$prefix" ]; then
            case "$file" in
              ${prefix}*) apply_label=true; break ;;
            esac
          elif [ -n "$suffix" ]; then
            case "$file" in
              *${suffix}) apply_label=true; break ;;
            esac
          fi
          ;;
        *)
          # Simple exact match
          case "$file" in
            $pattern) apply_label=true; break ;;
          esac
          ;;
      esac
    done

    $apply_label && break
  done
  IFS="$OLD_IFS"

  if $apply_label; then
    # Check if label already exists
    already_exists=false
    echo "$CURRENT_LABELS" | while IFS= read -r existing; do
      if [ "$existing" = "$label" ]; then
        already_exists=true
        break
      fi
    done

    if ! $already_exists; then
      LABELS_TO_ADD="${LABELS_TO_ADD}${label},"
      echo "Labeler: Will add label '${label}'"
    else
      echo "Labeler: Label '${label}' already exists"
    fi
  fi
done

# Apply labels via API
if [ -n "$LABELS_TO_ADD" ]; then
  # Remove trailing comma
  LABELS_TO_ADD=$(echo "$LABELS_TO_ADD" | sed 's/,$//')

  # Get current labels and add new ones
  ALL_LABELS="${CURRENT_LABELS}"
  for label in $(echo "$LABELS_TO_ADD" | tr ',' ' '); do
    # Check if label already in the list
    case "$ALL_LABELS" in
      *"$label"*) ;;
      *)
        if [ -n "$ALL_LABELS" ]; then
          ALL_LABELS="${ALL_LABELS},${label}"
        else
          ALL_LABELS="$label"
        fi
        ;;
    esac
  done

  # Update MR labels
  RESPONSE=$(curl --silent --request PUT \
    --header "PRIVATE-TOKEN: ${TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{\"labels\": \"${ALL_LABELS}\"}" \
    "${API_URL}/projects/${PROJECT_ID}/merge_requests/${MR_IID}")

  echo "Labeler: Successfully updated labels to '${ALL_LABELS}'"
else
  echo "Labeler: No new labels to add"
fi
