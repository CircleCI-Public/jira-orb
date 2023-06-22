#!/bin/bash

# create log file
JIRA_LOGFILE=/tmp/circleci_jira.log
touch $JIRA_LOGFILE
# Ensure status file exists
if [ ! -f "/tmp/circleci_jira_status" ]; then
  echo "Status file not found at /tmp/circleci_jira_status"
  exit 1
fi

# Functions to create environment variables
# Determine the VCS type
getVCS() {
  REGEXP="com\/([A-Za-z]+)\/"
  if [[ $CIRCLE_BUILD_URL =~ $REGEXP ]]; then
    PROJECT_VCS="${BASH_REMATCH[1]}"
    else
      echo "Unable to determine VCS type"
  fi
}

# Get the slug given the build url
getSlug() {
  if [[ "$PROJECT_VCS" == "circleci" ]]; then
    REGEXP="com\/([A-Za-z]+\/.*)"
    if [[ $CIRCLE_BUILD_URL =~ $REGEXP ]]; then
      PROJECT_SLUG="${BASH_REMATCH[1]}"
    fi
  else
    REGEXP="com\/([A-Za-z]+\/[A-Za-z0-9-]+\/[A-Za-z0-9-]+)\/"
    if [[ $CIRCLE_BUILD_URL =~ $REGEXP ]]; then
      PROJECT_SLUG="${BASH_REMATCH[1]}"
    fi
  fi
  if [[ ${#PROJECT_SLUG} -eq 0 ]]; then
    echo "Unable to determine project slug"
    exit 1
  fi
}

# Sets the JIRA_ISSUE_KEYS or prints an error
getIssueKeys() {
  KEY_ARRAY=()
  # Get branch keys
  if [[ "$CIRCLE_BRANCH" =~ $ORB_VAL_ISSUE_REGEXP ]]; then
    KEY_ARRAY+=( "${BASH_REMATCH[1]}")
  fi
  # Get commit keys (if enabled)
  if [[ "$COMMIT_MESSAGE" =~ $ORB_VAL_ISSUE_REGEXP ]]; then
    COMMIT_KEYS=("${BASH_REMATCH[1]}")
    if [[ "$ORB_BOOL_SCAN_COMMIT_BODY" == "1" ]]; then
      KEY_ARRAY+=("${COMMIT_KEYS[@]}")
    else
      echo "Issue keys found in commit, but not scanning commit body"
      echo "If you want to scan the commit body, set the 'scan_commit_body' parameter to true"
    fi
  fi
  # Exit if no keys found
  if [[ ${#KEY_ARRAY[@]} -eq 0 ]]; then
    message="No issue keys found in branch"
    dbgmessage="  Branch: $CIRCLE_BRANCH\n"
    if [[ "$ORB_BOOL_SCAN_COMMIT_BODY" == '1' ]]; then
      message+=" or commit message"
      dbgmessage+="  Commit: $COMMIT_MESSAGE\n"
    fi
    echo "$message"
    echo -e "$dbgmessage"
    printf "\nSkipping Jira notification\n\n"
    exit 0
  fi
  # Set the JIRA_ISSUE_KEYS variable to JSON array
  JIRA_ISSUE_KEYS=$(printf '%s\n' "${KEY_ARRAY[@]}" | jq -R . | jq -s .)
  echo "Issue keys found:"
  echo "$JIRA_ISSUE_KEYS" | jq -r '.[]'
  export JIRA_ISSUE_KEYS
}

# Post the payload to the CircleCI for Jira Forge app
postForge() {
  FORGE_PAYLOAD=$1
  echo "Posting payload to CircleCI for Jira Forge app"
  FORGE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${ORB_VAL_JIRA_WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: ${ORB_VAL_JIRA_OIDC_TOKEN}" \
    -d "${FORGE_PAYLOAD}")
  HTTP_BODY=$(echo "$FORGE_RESPONSE" | sed -e '$d')
  HTTP_STATUS=$(echo "$FORGE_RESPONSE" | tail -n 1)

  if [[ "$ORB_DEBUG_ENABLE" == "true" ]]; then
    echo
    echo "#### DEBUG ####"
    echo "Forge response:"
    echo "  HTTP Status: $HTTP_STATUS"
    echo "  HTTP Body:"
    echo "$HTTP_BODY" | jq '.'
    echo "###############"
  fi

  # Check for errors
  JIRA_ERRORS="$(echo "$HTTP_BODY" | jq -r '..|select(type == "object" and (has("errors") or has("error")))|(.errors // .error)')"
  if [[ "$HTTP_STATUS" -gt 299 || ${#JIRA_ERRORS} -gt 0 ]]; then
    printf "\nError posting payload to CircleCI for Jira Forge app\n"
    echo "  HTTP Status: $HTTP_STATUS"
    echo "  Errors:"
    echo "$JIRA_ERRORS" | jq '.'
    exit 1
  fi
}

# Verify any values that need to be present before continuing
verifyVars() {
  MSG=$(printf "OIDC Token: %s\nWebhook URL: %s\nEnvironment: %s\n" "$ORB_VAL_JIRA_OIDC_TOKEN" "$ORB_VAL_JIRA_WEBHOOK_URL" "$ORB_VAL_ENVIRONMENT")
  log "$MSG"

  if [[ -z "$ORB_VAL_JIRA_OIDC_TOKEN" ]]; then
    echo "'oidc_token' parameter is required"
    exit 1
  fi

  if ! [[ "$ORB_VAL_JIRA_WEBHOOK_URL" =~ ^https:\/\/([a-zA-Z0-9.-]+\.[A-Za-z]{2,6})(:[0-9]{1,5})?(\/.*)?$ ]]; then
    echo "'webhook_url' must be a valid URL"
    echo "  Value: $ORB_VAL_JIRA_WEBHOOK_URL"
    exit 1
  fi

  if [[ -z "$ORB_VAL_ENVIRONMENT" ]]; then
    echo "'environment' parameter is required"
    echo "  Value: $ORB_VAL_ENVIRONMENT"
    exit 1
  fi

}

log() {
  if [[ "$ORB_DEBUG_ENABLE" == "true" ]]; then
    {
      echo ""
      echo "$1"
      echo ""
    } >> $JIRA_LOGFILE
    echo "#### DEBUG ####"
    echo -e "$1"
    echo "###############"
  fi
}


# Sanetize the input
# ORB_VAL_JOB_TYPE - Enum string value of 'build' or 'deploy'
ORB_VAL_ENVIRONMENT=$(circleci env subst "${ORB_VAL_ENVIRONMENT}")
ORB_VAL_ENVIRONMENT_TYPE=$(circleci env subst "${ORB_VAL_ENVIRONMENT_TYPE}")
ORB_VAL_STATE_PATH=$(circleci env subst "${ORB_VAL_STATE_PATH}")
ORB_VAL_SERVICE_ID=$(circleci env subst "${ORB_VAL_SERVICE_ID}")
ORB_VAL_ISSUE_REGEXP=$(circleci env subst "${ORB_VAL_ISSUE_REGEXP}")
ORB_VAL_JIRA_OIDC_TOKEN=$(circleci env subst "${ORB_VAL_JIRA_OIDC_TOKEN}")
ORB_VAL_JIRA_WEBHOOK_URL=$(circleci env subst "${ORB_VAL_JIRA_WEBHOOK_URL}")
# ORB_BOOL_SCAN_COMMIT_BODY - 1 = true, 0 = false
# ORB_VAL_PIPELINE_ID - pipeline id
# ORB_VAL_PIPELINE_NUMBER - pipeline number
# ---
# Create custom variables
TIME_EPOCH=$(date +%s)
TIME_STAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
# ORB_DEBUG_TEST_COMMIT is only used in testing
COMMIT_MESSAGE=$(git show -s --format='%s' "${ORB_DEBUG_TEST_COMMIT:-$CIRCLE_SHA1}")
JIRA_BUILD_STATUS=$(cat /tmp/circleci_jira_status)
PROJECT_VCS=""
PROJECT_SLUG=""
JIRA_PIPELINE_URL="https://app.circleci.com/pipelines/$ORG_SLUG/$ORB_VAL_PIPELINE_NUMBER"
JIRA_ISSUE_KEYS=() # Set in getIssueKeys

# Built-ins - For reference
# CIRCLE_BUILD_URL is the URL of the current build
# CIRCLE_SHA1 is the commit hash of the current build
# CIRCLE_BRANCH is the branch name of the current build

# Set variables which require functions
## Variables are set directly rather than returned to improve error handling
getVCS
getSlug

# Export variables for use in envsubst
export ORB_VAL_ENVIRONMENT
export ORB_VAL_ENVIRONMENT_TYPE
export ORB_VAL_STATE_PATH
export ORB_VAL_SERVICE_ID
export ORB_VAL_ISSUE_REGEXP
export ORB_BOOL_SCAN_COMMIT_BODY
export ORB_VAL_PIPELINE_ID
export ORB_VAL_PIPELINE_NUMBER
export TIME_EPOCH
export TIME_STAMP
export COMMIT_MESSAGE
export JIRA_BUILD_STATUS
export PROJECT_SLUG
export JIRA_PIPELINE_URL
export JIRA_ISSUE_KEYS
export ORB_VAL_JIRA_WEBHOOK_URL
export PROJECT_VCS
export PROJECT_SLUG


main() {
  verifyVars
  getIssueKeys
  printf "Notification type: %s\n" "$ORB_VAL_JOB_TYPE"
  if [[ "$ORB_VAL_JOB_TYPE" == 'build' ]]; then
    PAYLOAD=$(echo "$JSON_BUILD_PAYLOAD" | circleci env subst)
    PAYLOAD=$(jq --argjson keys "$JIRA_ISSUE_KEYS" '.builds[0].issueKeys = $keys' <<< "$PAYLOAD")
    postForge "$PAYLOAD"
  elif [[ "$ORB_VAL_JOB_TYPE" == 'deployment' ]]; then
    PAYLOAD=$(echo "$JSON_DEPLOYMENT_PAYLOAD" | circleci env subst)
    # Set the issue keys array
    PAYLOAD=$(jq --argjson keys "$JIRA_ISSUE_KEYS" '.deployments[0].associations |= map(if .associationType == "issueIdOrKeys" then .values = $keys else . end)' <<< "$PAYLOAD")
    # Set ServiceID
    PAYLOAD=$(jq --arg serviceId "$ORB_VAL_SERVICE_ID" '.deployments[0].associations |= map(if .associationType == "serviceIdOrKeys" then .values = [$serviceId] else . end)' <<< "$PAYLOAD")
    if [[ "$ORB_DEBUG_ENABLE" == "true" ]]; then
      MSG=$(printf "PAYLOAD: %s\n" "$PAYLOAD")
      log "$MSG"
    fi
    postForge "$PAYLOAD"
  else
    echo "Unable to determine job type"
    exit 1
  fi
  printf "\nJira notification sent!\n\n"
  MSG=$(printf "sent=true")
  log "$MSG"
}

# Run the script
main