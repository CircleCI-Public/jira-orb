#!/bin/bash

# This script requires Bash v4+ or zsh.
# MacOS on CircleCI ships with Bash v3.x as the default shell
# This script determines which shell to execute the notify script in.

if [[ "$(uname -s)" == "Darwin" && "$SHELL" != "/bin/zsh" ]]; then
  echo "Running in ZSH on MacOS"
  /bin/zsh -c "setopt KSH_ARRAYS BASH_REMATCH SHWORDSPLIT; $JIRA_SCRIPT_NOTIFY"
else 
  /bin/bash -c "$JIRA_SCRIPT_NOTIFY"
fi
