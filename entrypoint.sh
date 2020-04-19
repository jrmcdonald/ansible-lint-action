#! /usr/bin/env bash

set -Eeuo pipefail

COLOUR_RED=$'\e[1;31m'
COLOUR_GREEN=$'\e[1;32m'
COLOUR_END=$'\e[0m'

# Filter out arguments that are not available to this action
# args:
#   $@: Arguments to be filtered
parse_args() {
  local opts=""
  while (("$#")); do
    case "$1" in
    -q | --quiet)
      opts="$opts -q"
      shift
      ;;
    -c)
      opts="$opts -c $2"
      shift 2
      ;;
    -p)
      opts="$opts -p"
      shift
      ;;
    -r)
      opts="$opts -r $2"
      shift 2
      ;;
    -R)
      opts="$opts -R"
      shift
      ;;
    -t)
      opts="$opts -t $2"
      shift 2
      ;;
    -x)
      opts="$opts -x $2"
      shift 2
      ;;
    --exclude)
      opts="$opts --exclude=$2"
      shift 2
      ;;
    --no-color)
      opts="$opts --no-color"
      shift
      ;;
    --parseable-severity)
      opts="$opts --parseable-severity"
      shift
      ;;
    --) # end argument parsing
      shift
      break
      ;;
    -*) # unsupported flags
      echo >&2 "ERROR: Unsupported flag: '$1'"
      exit 1
      ;;
    *) # positional arguments
      shift # ignore
      ;;
    esac
  done

  # set remaining positional arguments (if any) in their proper place
  eval set -- "$opts"

  echo "${opts/ /}"
  return 0
}

override_python_packages() {
  [[ -n "${OVERRIDE}" ]] && pip install ${OVERRIDE} && pip check
  echo "Completed installing override dependencies..."
}

comment_on_pullrequest() {
  local opts
  opts="${1}"

  local printableTargetList
  printableTargetList="${2}"

  local comment=""

  # Lint each of the targets individually.
  while read -r target; do
    if [[ "${target}" != "" ]]; then
      shopt -s globstar # Enable recursive glob patterns, such as '**/*.yml'.
      set +e            # Enable errors so that the output can be captured

      local targetOutput
      targetOutput=$(ansible-lint --nocolor ${opts} "${target}")
      local exitCode=${?}

      set -e
      shopt -u globstar

      # If individual linting fails then add to the comment.
      if [ ${exitCode} -ne 0 ]; then
        comment="${comment}
<details><summary><code>${target}</code></summary>

\`\`\`
${targetOutput}
\`\`\`

</details>"
      fi
    fi
  done <<<${TARGETS}

  # Wrap the indivudual comments in a block.
  local commentWrapper
  commentWrapper="#### \`ansible-lint -v ${opts} ${printableTargetList}\` Failed
${comment}

*Workflow: \`${GITHUB_WORKFLOW}\`, Action: \`${GITHUB_ACTION}\`*"

  # Construct payload and send to the GitHub API.
  printf "info: creating comment JSON payload\n"
  local payload
  payload=$(echo "${commentWrapper}" | jq -R --slurp '{body: .}')

  local commentsUrl
  commentsUrl=$(jq -r .pull_request.comments_url "${GITHUB_EVENT_PATH}")

  printf "info: commenting on the pull request\n"
  echo "${payload}" | curl -s -S -H "Authorization: token ${GITHUB_TOKEN}" --header "Content-Type: application/json" --data @- "${commentsUrl}" >/dev/null
}

# Generates client.
# args:
#   $@: additional options
# env:
#   [required] TARGETS : Files or directories (i.e., playbooks, tasks, handlers etc..) to be linted
ansible::lint() {
  : "${TARGETS?No targets to check. Nothing to do.}"
  : "${GITHUB_WORKSPACE?GITHUB_WORKSPACE has to be set. Did you use the actions/checkout action?}"
  pushd "${GITHUB_WORKSPACE}"

  override_python_packages
  local opts
  opts=$(parse_args "$@" || exit 1)

  local printableTargetList
  printableTargetList=$(echo ${TARGETS} | sed '/^[[:space:]]*$/d')
  printf "Executing 'ansible-lint -v --force-color ${opts} ${printableTargetList}'\n"

  shopt -s globstar # Enable recursive glob patterns, such as '**/*.yml'.
  set +e            # Enable errors so that the output can be captured

  # Gather the output of ansible-lint.
  local lintOutput
  lintOutput=$(ansible-lint -v --force-color ${opts} ${TARGETS} 2>&1)
  local exitCode=${?}

  set -e
  shopt -u globstar

  # Exit code of 0 indicates success. Print the output and exit.
  if [ ${exitCode} -eq 0 ]; then
    printf "${COLOUR_GREEN}Successfully linted '${printableTargetList}'${COLOUR_END}\n"
    echo "${lintOutput}"
    exit ${exitCode}
  fi

  printf >&2 "${COLOUR_RED}Linting errors were found in '${printableTargetList}':${COLOUR_END}\n"
  echo "${lintOutput}"

  # Comment on the pull request if necessary.
  if [[ "$GITHUB_EVENT_NAME" == "pull_request" && ("${INPUT_COMMENT}" == "1" || "${INPUT_COMMENT}" == "true") ]]; then
    comment_on_pullrequest "${opts}" "${printableTargetList}"
  fi

  exit ${exitCode}
}

args=("$@")

if [ "$0" = "${BASH_SOURCE[*]}" ]; then
  printf "Running Ansible Lint...\n"
  ansible::lint "${args[@]}"
fi
