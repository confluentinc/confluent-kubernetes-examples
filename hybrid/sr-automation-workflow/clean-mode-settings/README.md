Schema Registry Mode Cleanup Script
This script is a high-performance utility designed to clean up Confluent Schema Registry configurations by removing the mode setting from all subjects and contexts. This ensures that the operational mode (e.g., READWRITE, READONLY) is governed only by the global setting, preventing unexpected behavior from subject-level or context-level overrides.

The script is optimized for speed and clarity, using parallel processing and a real-time progress bar to handle registries with thousands of entries efficiently.

Features
High Performance: Processes subjects and contexts in parallel using xargs to dramatically reduce execution time.

Efficient: Uses an "optimistic DELETE" strategy, sending requests directly without a preliminary check to minimize network overhead.

Clear Progress Reporting: Displays a real-time progress bar instead of verbose logs, with a final summary of successes and failures.

Safe: Includes an interactive confirmation prompt before making any changes.

Flexible Configuration: All settings, including the target URL and credentials, are configured via environment variables for easy integration into different environments.

Resilient: curl commands include timeouts to prevent the script from stalling on unresponsive requests.

Prerequisites
Bash: A standard Unix-like shell. The script is designed to be portable across different Bash versions.

jq: A command-line JSON processor used to parse the list of subjects and contexts.

You can install jq using a package manager. For example:

# On Debian/Ubuntu
sudo apt-get install jq

# On macOS (using Homebrew)
brew install jq

Configuration
The script is configured using the following environment variables.

Variable

Description

Default Value

SCHEMA_REGISTRY_URL

The full URL of your Schema Registry instance.

http://localhost:8081

SCHEMA_REGISTRY_USER

The username for Basic Authentication. If set, authentication will be enabled.

(unset)

SCHEMA_REGISTRY_PASSWORD

The password for Basic Authentication.

(unset)

MAX_CONCURRENCY

The number of parallel curl requests to run. Increase this value for faster performance, depending on your server's and client's capacity.

10

Usage
Save the Script: Save the code as cleanup_mode_settings.sh.

Make it Executable:

chmod +x cleanup_mode_settings.sh

Set Environment Variables: Configure the script for your environment.

Example for an unauthenticated registry:

export SCHEMA_REGISTRY_URL="http://my-schema-registry:8081"
export MAX_CONCURRENCY=50 # Optional: Increase for speed

Example with Basic Authentication:

export SCHEMA_REGISTRY_URL="[https://secure-registry.example.com](https://secure-registry.example.com)"
export SCHEMA_REGISTRY_USER="my-user"
export SCHEMA_REGISTRY_PASSWORD="my-secret-password"

Run the Script:

./cleanup_mode_settings.sh

The script will ask for final confirmation before proceeding with the deletions.

Advanced Authentication Methods
While the script has built-in support for Basic Authentication, it can be easily adapted for other methods by modifying the CURL_OPTS array inside the process_subject and process_context functions.

1. TLS/SSL Client Authentication (mTLS)
If your registry uses mTLS, you would provide a client certificate and key.

Modification: Add the --cert and --key flags to CURL_OPTS.

# Inside the process_subject/process_context functions
local CURL_OPTS=("-s" "--connect-timeout" "5" "--max-time" "15" \
                 "--cert" "/path/to/client.pem" \
                 "--key" "/path/to/client.key")

2. Token-Based Authentication (OAuth/OIDC)
For token-based security, you would include a bearer token in the Authorization header.

Modification: Add a -H header flag to CURL_OPTS.

# You would typically get the token from an external command or variable
TOKEN="your-long-auth-token-here"

# Inside the process_subject/process_context functions
local CURL_OPTS=("-s" "--connect-timeout" "5" "--max-time" "15" \
                 "-H" "Authorization: Bearer ${TOKEN}")

Troubleshooting
jq: command not found: Ensure jq is installed and available in your system's PATH.

Authentication Errors: If you see 401 Unauthorized errors, double-check that your SCHEMA_REGISTRY_USER and SCHEMA_REGISTRY_PASSWORD environment variables are correctly set and exported.

Connection Timeouts: If the script fails with timeout errors, your SCHEMA_REGISTRY_URL may be incorrect, or there could be a network issue between the script's location and the registry.
