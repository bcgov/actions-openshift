#!/bin/bash

# Catch errors and unset variables
set -euo pipefail

# Input validation
if [ "$#" -lt 3 ]; then
    echo "Add, Remove or Check on PR-based users and databases."
    echo "Usage: $0 <add|remove|check> <github_pr_no> <cluster>"
    exit 1
fi

# Inputs and variables
COMMAND="${1}"
PR_NO="${2}"
CLUSTER="${3}"
MAX_USER_ADD_RETRIES=60
USER_ADD_SLEEP_SECONDS=10
# Check if postgres-crunchy exists or else exit
if ! oc get PostgresCluster/"${CLUSTER}"; then
    echo "Cluster ${CLUSTER} does not exist. Exiting."
    exit 0
fi

# Set target database and user
TARGET_USER="{\"databases\":[\"app-${PR_NO}\"], \"name\":\"app-${PR_NO}\"}"

# Check if the user already exists
CURRENT_USERS=$(oc get PostgresCluster/"${CLUSTER}" -o json | jq '.spec.users')
echo "${CURRENT_USERS}"

# Function to check if a user already exists
user_exists() {
    local user_name="$1"
    local current_users="$2"
    echo "${current_users}" | jq -e ".[] | select(.name == \"${user_name}\")" > /dev/null && echo 1 || echo 0
}

# Function to patch PostgresCluster with updated users
patch_postgres_cluster() {
    local cluster="$1"
    local updated_users="$2"
    local patch_json
    patch_json=$(jq -n --argjson users "${updated_users}" '{"spec": {"users": $users}}')
    oc patch PostgresCluster/"${CLUSTER}" --type=merge -p "${patch_json}"
}

# Function to wait for a secret to be created
wait_for_secret() {
    local secret_name="$1"
    for i in  $(seq 1 "$MAX_USER_ADD_RETRIES"); do
        if oc get secret "${secret_name}" -o jsonpath='{.metadata.name}' > /dev/null 2>&1; then
            echo "Secret created"
            return 0
        else
            echo "Attempt $i: Secret not created, waiting for $USER_ADD_SLEEP_SECONDS seconds"
            sleep $USER_ADD_SLEEP_SECONDS
        fi
    done
    echo "Error: Secret ${secret_name} was not created after $MAX_USER_ADD_RETRIES attempts."
    return 1
}
# Function to retry a command a limited number of times
# Arguments:
#   $1 - max_attempts: maximum number of times to try running the command
#   $2 - sleep_seconds: number of seconds to sleep between attempts
#   $@ - the command (and its arguments) to execute
# Returns:
#   0 if the command succeeds within the allowed attempts, otherwise the
#   exit code of the last failed attempt.
retry() {
    local -r max_attempts="$1"; shift
    local -r sleep_seconds="$1"; shift

    local attempt=1
    
    while true; do
        if "$@"; then
            return 0
        fi
        
        local rc=$?
        
        if (( attempt >= max_attempts )); then
            echo "All ${max_attempts} attempts failed (last exit:  ${rc})" >&2
            return "$rc"
        fi

        echo "Attempt ${attempt}/${max_attempts} failed (exit ${rc}). Retrying in ${sleep_seconds}s..." >&2
        sleep "$sleep_seconds"
        (( attempt++ ))
    done
}
# Check if the user already exists
USER_EXISTS=$(user_exists "app-${PR_NO}" "${CURRENT_USERS}")

# Echo intent
echo -e "Cluster: ${CLUSTER}"
echo -e "PR User: app-${PR_NO}"
echo -e "Command: ${COMMAND}\n"

# Perform list, add or remove
if [ "$COMMAND" == "check" ]; then
    if [ "$USER_EXISTS" -eq 1 ]; then
      echo "User ${PR_NO} already exists."
    else
      echo "User ${PR_NO} does not exist."
    fi
elif [ "$COMMAND" == "add" ]; then
    if [ "$USER_EXISTS" -eq 1 ]; then
      echo "User already exists. Exiting."
      exit 0
    fi

    UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson TARGET_USER "${TARGET_USER}" '. + [$TARGET_USER]')
    patch_postgres_cluster "${CLUSTER}" "${UPDATED_USERS}"

    # Wait for the secret to be created
    wait_for_secret "${CLUSTER}-pguser-app-${PR_NO}" || exit 1

elif [ "$COMMAND" == "remove" ]; then
    if [ "$USER_EXISTS" -eq 0 ]; then
      echo "User does not exist to remove. Exiting."
      exit 0
    fi

    UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson user "${TARGET_USER}" 'map(select(. != $user))')
    patch_postgres_cluster "${CLUSTER}" "${UPDATED_USERS}"

    # Get primary crunchy pod and remove the role and database
    CRUNCHY_PG_PRIMARY_POD_NAME=$(oc get pods -l postgres-operator.crunchydata.com/cluster="${CLUSTER}",postgres-operator.crunchydata.com/role=master -o json | jq -r '.items[0].metadata.name')
    echo "${CRUNCHY_PG_PRIMARY_POD_NAME}"

    if ! retry 5 2 oc exec "${CRUNCHY_PG_PRIMARY_POD_NAME}" -- bash -c "
        psql -U postgres -d postgres <<-SQL
            SELECT pg_terminate_backend(pg_stat_activity.pid)
            FROM pg_stat_activity
            WHERE pg_stat_activity.datname = 'app-${PR_NO}'
            AND pid <> pg_backend_pid();
            
            DROP DATABASE IF EXISTS \"app-${PR_NO}\";
            DROP ROLE IF EXISTS \"app-${PR_NO}\";
        SQL
        "; then
        echo "Failed to cleanup database and role for app-${PR_NO}" >&2
        exit 1
    fi
else
    echo "Invalid command: $COMMAND. Use 'add', 'remove' or 'check'."
    exit 1
fi
