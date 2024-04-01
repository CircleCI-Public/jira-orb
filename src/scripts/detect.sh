#!/bin/bash

jira_status=${JIRA_VAL_STATE:-$JOB_STATUS}

if [[ "${JIRA_VAL_JOB_TYPE}" == "build" && "${JIRA_VAL_STATE}" == "rolled_back" ]]; then
  echo "Cannot use 'rolled_back' build job type. Using '${JOB_STATUS}'"
  jira_status="${JOB_STATUS}"
elif [[ "${JIRA_VAL_STATE}" == "unknown" ]]; then
  jira_status="${JOB_STATUS}"
fi

echo "${jira_status}" >/tmp/circleci_jira_status
