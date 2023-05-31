#!/bin/bash
ORB_VAL_JOB_TYPE=$(circleci env subst "${ORB_VAL_JOB_TYPE}")
ORB_VAL_ENVIRONMENT=$(circleci env subst "${ORB_VAL_ENVIRONMENT}")
ORB_VAL_ENVIRONMENT_TYPE=$(circleci env subst "${ORB_VAL_ENVIRONMENT_TYPE}")
ORB_VAL_STATE_PATH=$(circleci env subst "${ORB_VAL_STATE_PATH}")
ORB_VAL_SERVICE_ID=$(circleci env subst "${ORB_VAL_SERVICE_ID}")
ORB_VAL_ISSUE_REGEXP=$(circleci env subst "${ORB_VAL_ISSUE_REGEXP}")
# ORB_BOOL_SCAN_COMMIT_BODY - 1 = true, 0 = false

