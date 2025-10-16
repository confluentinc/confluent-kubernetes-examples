#!/bin/bash

# A bash script to delete the 'mode' setting from all subjects or contexts in a schema registry.
# This script processes requests in parallel to improve speed by sending DELETE requests directly.
# This script does NOT affect the global mode setting.
#
# DEPENDENCY: This script requires 'jq', a command-line JSON processor.
# Please install it before running (e.g., 'sudo apt-get install jq' or 'brew install jq').

# --- Configuration ---
# The base URL for the schema registry.
# This can be overridden by setting the SCHEMA_REGISTRY_URL environment variable.
# Example: export SCHEMA_REGISTRY_URL="https://my-registry.example.com"
SCHEMA_REGISTRY_URL=${SCHEMA_REGISTRY_URL:-"http://localhost:8081"}

# The maximum number of concurrent requests to send to the schema registry.
# Adjust this based on your system and the server's capacity.
# For faster performance, try increasing this value to 25, 50, or higher.
MAX_CONCURRENCY=10

# --- Authentication ---
# For security, credentials should be provided via environment variables.
# Example:
#   export SCHEMA_REGISTRY_USER="my-user"
#   export SCHEMA_REGISTRY_PASSWORD="my-secret-password"
#   ./cleanup_mode_settings.sh

# --- Helper Functions ---

# Renders a progress bar.
# Arguments: 1. current value, 2. total value
render_progress_bar() {
    local current=$1
    local total=$2
    local width=50

    # Calculate percentage
    local percentage=$(( current * 100 / total ))
    local completed=$(( width * percentage / 100 ))
    local remaining=$(( width - completed ))

    # Build the bar string
    local bar=$(printf "%${completed}s" | tr ' ' '#')
    local space=$(printf "%${remaining}s")

    # Print the bar to stderr to avoid interfering with stdout processing
    printf "\rProgress: [%s%s] %d%% (%d/%d)" "$bar" "$space" "$percentage" "$current" "$total" >&2
}


# --- API Functions ---

get_all_subjects() {
    local url="${SCHEMA_REGISTRY_URL}/subjects"
    echo "INFO: Fetching all subjects from ${url}" >&2
    
    local CURL_OPTS=("-s")
    if [[ -n "$SCHEMA_REGISTRY_USER" ]]; then
        CURL_OPTS+=("-u" "$SCHEMA_REGISTRY_USER:$SCHEMA_REGISTRY_PASSWORD")
    fi
    
    local response
    response=$(curl "${CURL_OPTS[@]}" -X GET "$url")
    
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo "ERROR: Failed to fetch subjects. Please check the URL, network, and credentials." >&2
        return 1
    fi
    echo "$response"
}

get_all_contexts() {
    local url="${SCHEMA_REGISTRY_URL}/contexts"
    echo "INFO: Fetching all contexts from ${url}" >&2

    local CURL_OPTS=("-s")
    if [[ -n "$SCHEMA_REGISTRY_USER" ]]; then
        CURL_OPTS+=("-u" "$SCHEMA_REGISTRY_USER:$SCHEMA_REGISTRY_PASSWORD")
    fi

    local response
    response=$(curl "${CURL_OPTS[@]}" -X GET "$url")

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo "ERROR: Failed to fetch contexts. Please check the URL, network, and credentials." >&2
        return 1
    fi
    echo "$response"
}


# --- Item Processing Functions (for parallel execution) ---

process_subject() {
    local subject_name=$1
    
    # Performance-tuned curl options:
    # --connect-timeout: Fail fast if connection isn't made in 5s.
    # --max-time: Limit the total operation time to 15s.
    local CURL_OPTS=("-s" "--connect-timeout" "5" "--max-time" "15")

    if [[ -n "$SCHEMA_REGISTRY_USER" ]]; then
        CURL_OPTS+=("-u" "$SCHEMA_REGISTRY_USER:$SCHEMA_REGISTRY_PASSWORD")
    fi

    local delete_url="${SCHEMA_REGISTRY_URL}/subjects/${subject_name}/mode"
    local delete_status
    delete_status=$(curl "${CURL_OPTS[@]}" -X DELETE -o /dev/null -w "%{http_code}" "$delete_url")
    
    # Treat 2xx (Success) and 404 (Not Found) as a successful outcome.
    if [[ "$delete_status" -ge 200 && "$delete_status" -lt 300 || "$delete_status" -eq 404 ]]; then
        echo "SUCCESS"
    else
        # Print error to stderr so it doesn't get processed by the progress bar loop
        echo -e "\n -> FAILED for subject '${subject_name}' (HTTP: ${delete_status})" >&2
        echo "FAILURE"
    fi
}
export -f process_subject

process_context() {
    local context_name=$1

    # Performance-tuned curl options:
    # --connect-timeout: Fail fast if connection isn't made in 5s.
    # --max-time: Limit the total operation time to 15s.
    local CURL_OPTS=("-s" "--connect-timeout" "5" "--max-time" "15")

    if [[ -n "$SCHEMA_REGISTRY_USER" ]]; then
        CURL_OPTS+=("-u" "$SCHEMA_REGISTRY_USER:$SCHEMA_REGISTRY_PASSWORD")
    fi

    local delete_url="${SCHEMA_REGISTRY_URL}/contexts/${context_name}/mode"
    local delete_status
    delete_status=$(curl "${CURL_OPTS[@]}" -X DELETE -o /dev/null -w "%{http_code}" "$delete_url")

    # Treat 2xx (Success) and 404 (Not Found) as a successful outcome.
    if [[ "$delete_status" -ge 200 && "$delete_status" -lt 300 || "$delete_status" -eq 404 ]]; then
        echo "SUCCESS"
    else
        # Print error to stderr so it doesn't get processed by the progress bar loop
        echo -e "\n -> FAILED for context '${context_name}' (HTTP: ${delete_status})" >&2
        echo "FAILURE"
    fi
}
export -f process_context


# --- Main Script Logic ---

main() {
    if [[ -n "$1" ]]; then
        echo "ERROR: This script does not accept any arguments." >&2
        exit 1
    fi
    
    echo "--- Starting script in LIVE mode. Changes WILL be applied. ---"
    read -p "Are you sure you want to proceed with live changes? (yes/no): " proceed
    if [[ "$(echo "$proceed" | tr '[:upper:]' '[:lower:]')" != "yes" ]]; then
        echo "Aborting script."
        return
    fi
    
    echo "INFO: Using a maximum of ${MAX_CONCURRENCY} parallel jobs."

    # --- Process Contexts ---
    echo -e "\n--- Processing Contexts ---" >&2
    local all_contexts_json=$(get_all_contexts)
    local c_total=0
    local c_success=0
    local c_failure=0
    local c_processed=0
    if [ $? -eq 0 ] && [ -n "$all_contexts_json" ] && [ "$all_contexts_json" != "[]" ]; then
        c_total=$(echo "$all_contexts_json" | jq '. | length')
        # Export variables and functions needed by the sub-shells
        export SCHEMA_REGISTRY_URL
        export SCHEMA_REGISTRY_USER
        export SCHEMA_REGISTRY_PASSWORD
        export -f process_context
        
        while read -r result; do
            (( c_processed++ ))
            render_progress_bar "$c_processed" "$c_total"
            if [[ "$result" == "SUCCESS" ]]; then
                (( c_success++ ))
            else
                (( c_failure++ ))
            fi
        done < <(echo "$all_contexts_json" | jq -r '.[]' | xargs -P "$MAX_CONCURRENCY" -I {} bash -c 'process_context "{}"')
        echo "" >&2 # Newline after progress bar
    else
        echo "WARNING: No contexts found or failed to fetch. Skipping." >&2
    fi

    # --- Process Subjects ---
    echo -e "\n--- Processing Subjects ---" >&2
    local all_subjects_json=$(get_all_subjects)
    local s_total=0
    local s_success=0
    local s_failure=0
    local s_processed=0
    if [ $? -eq 0 ] && [ -n "$all_subjects_json" ] && [ "$all_subjects_json" != "[]" ]; then
        s_total=$(echo "$all_subjects_json" | jq '. | length')
        # Export variables and functions needed by the sub-shells
        export SCHEMA_REGISTRY_URL
        export SCHEMA_REGISTRY_USER
        export SCHEMA_REGISTRY_PASSWORD
        export -f process_subject

        while read -r result; do
            (( s_processed++ ))
            render_progress_bar "$s_processed" "$s_total"
            if [[ "$result" == "SUCCESS" ]]; then
                (( s_success++ ))
            else
                (( s_failure++ ))
            fi
        done < <(echo "$all_subjects_json" | jq -r '.[]' | xargs -P "$MAX_CONCURRENCY" -I {} bash -c 'process_subject "{}"')
        echo "" >&2 # Newline after progress bar
    else
        echo "WARNING: No subjects found or failed to fetch. Skipping." >&2
    fi


    # --- Final Summary ---
    echo -e "\n--- Script Finished ---"
    echo "Summary (Live Run):"
    echo " - Contexts: ${c_success} succeeded, ${c_failure} failed (out of ${c_total} total)."
    echo " - Subjects: ${s_success} succeeded, ${s_failure} failed (out of ${s_total} total)."
    echo "-----------------------"
}

# Pass all script arguments to the main function
main "$@"


