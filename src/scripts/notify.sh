#!/bin/bash

# create log file
JIRA_LOGFILE=/tmp/circleci_jira.log
touch $JIRA_LOGFILE
# Ensure status file exists
if [ ! -f "/tmp/circleci_jira_status" ]; then
  echo "Status file not found at /tmp/circleci_jira_status"
  exit 1 # Critical error, do not skip
fi

# Functions to create environment variables
# Determine the VCS type
getVCS() {
  REGEXP="com\/([A-Za-z]+)\/"
  if [[ $CIRCLE_BUILD_URL =~ $REGEXP ]]; then
    PROJECT_VCS="${BASH_REMATCH[1]}"
  else
    echo "Unable to determine VCS type"
    exit 1 # Critical error, do not skip
  fi
}

errorOut() {
  echo "Exiting..."
  STATUS=${1:-0}
  if [[ "$JIRA_BOOL_IGNORE_ERRORS" == "1" ]]; then
    STATUS=0
  fi
  exit "$STATUS"
}

# Get the slug given the build url
getSlug() {
  if [[ "$PROJECT_VCS" == "circleci" ]]; then
    REGEXP="com\/([A-Za-z]+\/.*)"
    if [[ $CIRCLE_BUILD_URL =~ $REGEXP ]]; then
      PROJECT_SLUG="${BASH_REMATCH[1]}"
    fi
  else
    REGEXP="com\/([A-Za-z]+\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/"
    if [[ $CIRCLE_BUILD_URL =~ $REGEXP ]]; then
      PROJECT_SLUG="${BASH_REMATCH[1]}"
    fi
  fi
  if [[ ${#PROJECT_SLUG} -eq 0 ]]; then
    echo "Unable to determine project slug"
    exit 1 # Critical error, do not skip
  fi
}

# Accepts a string and returns an array of keys
parseKeys() {
  local KEY_ARRAY=()
  while [[ "$1" =~ $JIRA_VAL_ISSUE_REGEXP ]]; do
    KEY_ARRAY+=("${BASH_REMATCH[1]}")
    # Remove the matched part from the string so we can continue matching the rest
    local rest="${1#*"${BASH_REMATCH[0]}"}"
    set -- "$rest"
  done
  echo "${KEY_ARRAY[@]}"
}

remove_duplicates() {
  declare -A seen
  # Declare UNIQUE_KEYS as a global variable
  UNIQUE_KEYS=()
  
  for value in "$@"; do
    # Splitting value into array by space, considering space-separated keys in a single string
    for single_value in $value; do
      TRIMMED_VALUE="$(echo -e "${single_value}" | tr -d '[:space:]')"

      # If the trimmed value has not been seen before, add it to the UNIQUE_KEYS array and mark it as seen
      if [[ ! -v seen["$TRIMMED_VALUE"] ]]; then
        UNIQUE_KEYS+=("$TRIMMED_VALUE")
        seen["$TRIMMED_VALUE"]=1
      fi
    done
  done
}

# Sets the JIRA_ISSUE_KEYS or prints an error
getIssueKeys() {
  local KEY_ARRAY=()

  # Parse keys from branch and commit message
  local BRANCH_KEYS
  BRANCH_KEYS="$(parseKeys "$CIRCLE_BRANCH")"
  local COMMIT_KEYS
  COMMIT_KEYS="$(parseKeys "$COMMIT_MESSAGE")"
  BODY_KEYS="$(parseKeys "$COMMIT_BODY")"
  log "GETTING TAG KEYS"
  local TAG_KEYS
  TAG_KEYS="$(getTagKeys)"

  # Check if the parsed keys are not empty before adding to the array.
  [[ -n "$BRANCH_KEYS" ]] && KEY_ARRAY+=("$BRANCH_KEYS")
  [[ -n "$COMMIT_KEYS" ]] && KEY_ARRAY+=("$COMMIT_KEYS")
  [[ -n "$BODY_KEYS" ]] && KEY_ARRAY+=("$BODY_KEYS")
  [[ -n "$TAG_KEYS" ]] && KEY_ARRAY+=("$TAG_KEYS")

  # Remove duplicates
  remove_duplicates "${KEY_ARRAY[@]}"
  KEY_ARRAY=("${UNIQUE_KEYS[@]}")

  # Exit if no keys found
  if [[ ${#KEY_ARRAY[@]} -eq 0 ]]; then
    local message="No issue keys found in branch, commit message, or tag"
    local dbgmessage="  Branch: $CIRCLE_BRANCH\n"
    dbgmessage+="  Commit: $COMMIT_MESSAGE\n"
    dbgmessage+="  Body: $COMMIT_BODY\n"
    dbgmessage+="  Tag: $(git tag --points-at HEAD -l --format='%(tag) %(subject)' )\n"
    echo "$message"
    echo -e "$dbgmessage"
    printf "\nSkipping Jira notification\n\n"
    exit 0
  fi

  # Set the JIRA_ISSUE_KEYS variable to JSON array
  JIRA_ISSUE_KEYS=$(printf '%s\n' "${KEY_ARRAY[@]}" | jq -R . | jq -s .)
  echo "Issue keys found:"
  echo "$JIRA_ISSUE_KEYS" | jq -r '.[]'
  
  # Export JIRA_ISSUE_KEYS for use in other scripts or sessions
  export JIRA_ISSUE_KEYS
}


# Post the payload to the CircleCI for Jira Forge app
postForge() {
  FORGE_PAYLOAD=$1
  COUNT=${2:-1}
  echo "Posting payload to CircleCI for Jira Forge app"
  FORGE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${JIRA_VAL_JIRA_WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: ${JIRA_VAL_JIRA_OIDC_TOKEN}" \
    -d "${FORGE_PAYLOAD}")
  HTTP_BODY=$(echo "$FORGE_RESPONSE" | sed -e '$d')
  HTTP_STATUS=$(echo "$FORGE_RESPONSE" | tail -n 1)
  MSG=$(printf "HTTP Status: %s\nHTTP Body: %s\n" "$HTTP_STATUS" "$HTTP_BODY")
  log "$MSG"

  # Check for errors
  if ! JIRA_ERRORS="$(echo "$HTTP_BODY" | jq -r '..|select(type == "object" and (has("errors") or has("error")))|(.errors // .error)')";then
    echo "Error parsing response"
    errorOut 1
  fi
  if [[ "$HTTP_STATUS" -gt 299 || ${#JIRA_ERRORS} -gt 0 ]]; then
    printf "\nError posting payload to CircleCI for Jira Forge app\n"
    echo "  HTTP Status: $HTTP_STATUS"
    echo "  Errors:"
    echo "$JIRA_ERRORS" | jq '.'
  fi
  if [[ "$HTTP_STATUS" -gt 299 && "$HTTP_STATUS" -lt 399 ]] && [[ "$COUNT" -lt 5 ]]; then
    echo "Retrying... ($((COUNT + 1)))"
    sleep 3
    postForge "$FORGE_PAYLOAD" "$((COUNT + 1))"
  elif [[ "$HTTP_STATUS" -gt 399 ]]; then
    errorOut 1
  fi
}

# Verify any values that need to be present before continuing
verifyVars() {
  MSG=$(printf "OIDC Token: %s\nWebhook URL: %s\nEnvironment: %s\n" "$JIRA_VAL_JIRA_OIDC_TOKEN" "$JIRA_VAL_JIRA_WEBHOOK_URL" "$JIRA_VAL_ENVIRONMENT")
  log "$MSG"

  if [[ -z "$JIRA_VAL_JIRA_OIDC_TOKEN" ]]; then
    echo "'oidc_token' parameter is required"
    exit 1 # Critical error, do not skip
  fi

  if ! [[ "$JIRA_VAL_JIRA_WEBHOOK_URL" =~ ^https:\/\/([a-zA-Z0-9.-]+\.[A-Za-z]{2,6})(:[0-9]{1,5})?(\/.*)?$ ]]; then
    echo "  Please check the value of the 'webhook_url' parameter and ensure it contains a valid URL or a valid environment variable"
    echo "  Value: $JIRA_VAL_JIRA_WEBHOOK_URL"
    exit 1 # Critical error, do not skip
  fi

  if [[ -z "$JIRA_VAL_ENVIRONMENT" ]]; then
    echo "'environment' parameter is required"
    echo "  Value: $JIRA_VAL_ENVIRONMENT"
    exit 1 # Critical error, do not skip
  fi

}

log() {
  if [[ "$JIRA_DEBUG_ENABLE" == "true" ]]; then
    {
      echo ""
      echo "$1"
      echo ""
    } >>$JIRA_LOGFILE
    printf "\n  #### DEBUG ####\n  %s\n  ###############\n\n" "$1"
  fi
}

getTags() {
  local TAG_ARRAY=()
  GIT_TAG=$(git tag --points-at HEAD)
  [[ -n  "$GIT_TAG" ]] && TAG_ARRAY+=("$GIT_TAG")
  echo "${TAG_ARRAY[@]}"
}

getTagKeys() {
  local TAG_KEYS=()
  local TAGS
  TAGS="$(getTags)"
  for TAG in $TAGS; do
    local ANNOTATION
    ANNOTATION="$(git tag -l -n1 "$TAG")"
    [ -n "$ANNOTATION" ] || continue
    TAG_KEYS+=("$(parseKeys "$ANNOTATION")")
  done
  echo "${TAG_KEYS[@]}"
}

# Sanetize the input
# JIRA_VAL_JOB_TYPE - Enum string value of 'build' or 'deploy'
# JIRA_BOOL_DEBUG - 1 = true, 0 = false
if [[ "$JIRA_BOOL_DEBUG" -eq 1 ]]; then
  JIRA_DEBUG_ENABLE="true"
else
  JIRA_DEBUG_ENABLE="false"
fi
JIRA_LOG_LEVEL=$([ "$JIRA_DEBUG_ENABLE" = true ] && echo "log" || echo "error")
JIRA_VAL_ENVIRONMENT=$(circleci env subst "${JIRA_VAL_ENVIRONMENT}")
JIRA_VAL_ENVIRONMENT_TYPE=$(circleci env subst "${JIRA_VAL_ENVIRONMENT_TYPE}")
JIRA_VAL_STATE_PATH=$(circleci env subst "${JIRA_VAL_STATE_PATH}")
JIRA_VAL_SERVICE_ID=$(circleci env subst "${JIRA_VAL_SERVICE_ID}")
JIRA_VAL_ISSUE_REGEXP=$(circleci env subst "${JIRA_VAL_ISSUE_REGEXP}")
JIRA_VAL_JIRA_OIDC_TOKEN=$(circleci env subst "${JIRA_VAL_JIRA_OIDC_TOKEN}")
JIRA_VAL_JIRA_WEBHOOK_URL=$(circleci env subst "${JIRA_VAL_JIRA_WEBHOOK_URL}")
# Add the log parameter to the URL
JIRA_VAL_JIRA_WEBHOOK_URL="${JIRA_VAL_JIRA_WEBHOOK_URL}?verbosity=${JIRA_LOG_LEVEL}"
# JIRA_VAL_PIPELINE_ID - pipeline id
# JIRA_VAL_PIPELINE_NUMBER - pipeline number
TIME_EPOCH=$(date +%s)
TIME_STAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
# JIRA_DEBUG_TEST_COMMIT is only used in testing
COMMIT_MESSAGE=$(git show -s --format='%s' "${JIRA_DEBUG_TEST_COMMIT:-$CIRCLE_SHA1}")
COMMIT_BODY=$(git show -s --format='%b' "${JIRA_DEBUG_TEST_COMMIT:-$CIRCLE_SHA1}")
JIRA_BUILD_STATUS=$(cat /tmp/circleci_jira_status)
PROJECT_VCS=""
PROJECT_SLUG=""
JIRA_ISSUE_KEYS=() # Set in getIssueKeys

if [[ "$JIRA_BUILD_STATUS" == "failed" && -f "/tmp/circleci_jira_failed_reported" ]]; then
  echo "Failed status previously reported in this workflow. Skipping"
  errorOut 0
fi

# Built-ins - For reference
# CIRCLE_BUILD_URL is the URL of the current build
# CIRCLE_SHA1 is the commit hash of the current build
# CIRCLE_BRANCH is the branch name of the current build

# Set variables which require functions
## Variables are set directly rather than returned to improve error handling
getVCS
getSlug
JIRA_PIPELINE_URL="https://app.circleci.com/pipelines/$PROJECT_SLUG/$JIRA_VAL_PIPELINE_NUMBER"

# Export variables for use in envsubst
export JIRA_VAL_ENVIRONMENT
export JIRA_VAL_ENVIRONMENT_TYPE
export JIRA_VAL_STATE_PATH
export JIRA_VAL_SERVICE_ID
export JIRA_VAL_ISSUE_REGEXP
export JIRA_VAL_PIPELINE_ID
export JIRA_VAL_PIPELINE_NUMBER
export TIME_EPOCH
export TIME_STAMP
export COMMIT_MESSAGE
export COMMIT_BODY
export JIRA_BUILD_STATUS
export PROJECT_SLUG
export JIRA_PIPELINE_URL
export JIRA_ISSUE_KEYS
export JIRA_VAL_JIRA_WEBHOOK_URL
export PROJECT_VCS
export PROJECT_SLUG
export OBR_DEBUG_ENABLE
export JIRA_LOG_LEVEL

main() {
  if [[ "$JIRA_DEBUG_ENABLE" == "true" ]]; then
    echo "Debugging Enabled"
  fi
  verifyVars
  getIssueKeys
  printf "Notification type: %s\n" "$JIRA_VAL_JOB_TYPE"
  if [[ "$JIRA_VAL_JOB_TYPE" == 'build' ]]; then
    PAYLOAD=$(echo "$JSON_BUILD_PAYLOAD" | circleci env subst)
    if ! PAYLOAD=$(jq --argjson keys "$JIRA_ISSUE_KEYS" '.builds[0].issueKeys = $keys' <<<"$PAYLOAD");then
      echo "Error setting issue keys"
      errorOut 1
    fi
    postForge "$PAYLOAD"
  elif [[ "$JIRA_VAL_JOB_TYPE" == 'deployment' ]]; then
    PAYLOAD=$(echo "$JSON_DEPLOYMENT_PAYLOAD" | circleci env subst)
    # Set the issue keys array
    if ! PAYLOAD=$(jq --argjson keys "$JIRA_ISSUE_KEYS" '.deployments[0].associations |= map(if .associationType == "issueIdOrKeys" then .values = $keys else . end)' <<<"$PAYLOAD"); then
      echo "Error setting issue keys"
      errorOut 1
    fi
    # Set ServiceID
    if ! PAYLOAD=$(jq --arg serviceId "$JIRA_VAL_SERVICE_ID" '.deployments[0].associations |= map(if .associationType == "serviceIdOrKeys" then .values = [$serviceId] else . end)' <<<"$PAYLOAD"); then
      echo "Error setting service id"
      errorOut 1
    fi
    if [[ "$JIRA_DEBUG_ENABLE" == "true" ]]; then
      MSG=$(printf "PAYLOAD: %s\n" "$PAYLOAD")
      log "$MSG"
    fi
    postForge "$PAYLOAD"
  else
    echo "Unable to determine job type"
    exit 1 # Critical error, do not skip
  fi

  if [[ "$JIRA_BUILD_STATUS" == "failed" ]]; then
    # Mark that we've successfully reported the error. This file is
    # used above to prevent sending the failure notification with
    # multiple uses of the jira/notify command for different 
    # successful deployment states since those jobs will always run
    touch /tmp/circleci_jira_failed_reported
  fi

  printf "\nJira notification sent!\n\n"
  MSG=$(printf "sent=true")
  log "$MSG"
}

# Run the script
main
