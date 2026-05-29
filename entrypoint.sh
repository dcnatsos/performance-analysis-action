#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cyclopt Performance Action — Entrypoint
#
# This script orchestrates the full performance test lifecycle:
#   1. Wait for the application to be healthy
#   2. Initialize a run with the Cyclopt backend
#   3. Download the compiled runner binary
#   4. Execute the binary (which runs k6 tests internally)
#   5. Fetch formatted results from the backend
#   6. Post a PR comment with results (if triggered by a PR)
#   7. Set the GitHub Action status
#   8. Cleanup
# =============================================================================

# ---------------------------------------------------------------------------
# Inputs (injected by GitHub Actions via environment variables)
# ---------------------------------------------------------------------------
CYCLOPT_TOKEN="${INPUT_TOKEN:?'Error: token input is required'}"
TARGET_URL="${INPUT_TARGET_URL:?'Error: target-url input is required'}"
HEALTH_CHECK_PATH="${INPUT_HEALTH_CHECK_PATH:-/health}"
HEALTH_CHECK_TIMEOUT="${INPUT_HEALTH_CHECK_TIMEOUT:-60}"
CYCLOPT_API_URL="${INPUT_CYCLOPT_API_URL:-https://server.cyclopt.com}"

# Strip trailing slash from API URL
CYCLOPT_API_URL="${CYCLOPT_API_URL%/}"

BINARY_PATH="/tmp/cyclopt-runner"
RUNNER_EXIT_CODE=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { echo "::group::$1"; }
endlog(){ echo "::endgroup::"; }
info()  { echo "[cyclopt] $*"; }
warn()  { echo "::warning::[cyclopt] $*"; }
error() { echo "::error::[cyclopt] $*"; }

# Mask the token so it never appears in logs
echo "::add-mask::${CYCLOPT_TOKEN}"

cleanup() {
    info "Cleaning up..."
    rm -f "${BINARY_PATH}"
    info "Cleanup complete."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Wait for the application to be healthy
# ---------------------------------------------------------------------------
log "Waiting for application health check"

HEALTH_URL="${TARGET_URL%/}${HEALTH_CHECK_PATH}"
info "Polling ${HEALTH_URL} (timeout: ${HEALTH_CHECK_TIMEOUT}s)"

elapsed=0
healthy=false

while [ "${elapsed}" -lt "${HEALTH_CHECK_TIMEOUT}" ]; do
    http_code=$(curl -s -L -o /dev/null -w "%{http_code}" --max-time 5 "${HEALTH_URL}" 2>/dev/null || echo "000")

    if [ "${http_code}" = "200" ]; then
        healthy=true
        break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
done

if [ "${healthy}" != "true" ]; then
    error "Application health check failed. ${HEALTH_URL} did not return HTTP 200 within ${HEALTH_CHECK_TIMEOUT}s (last status: ${http_code})"
    error "Make sure your application is running and the health check endpoint is correct."
    exit 1
fi

info "Application is healthy (${elapsed}s elapsed)"
endlog

# ---------------------------------------------------------------------------
# Step 2: Initialize run with the Cyclopt backend
# ---------------------------------------------------------------------------
log "Initializing Cyclopt run"

# Gather GitHub context
COMMIT_SHA="${GITHUB_SHA:-unknown}"
BRANCH="${GITHUB_REF_NAME:-unknown}"
TRIGGER_TYPE="${GITHUB_EVENT_NAME:-unknown}"
RUNNER_OS_RAW="${RUNNER_OS:-linux}"
RUNNER_ARCH_RAW="${RUNNER_ARCH:-X64}"

case "$(echo "${RUNNER_OS_RAW}" | tr '[:upper:]' '[:lower:]')" in
    linux) RUNNER_OS_NORMALIZED="linux" ;;
    macos) RUNNER_OS_NORMALIZED="darwin" ;;
    windows) RUNNER_OS_NORMALIZED="windows" ;;
    *) RUNNER_OS_NORMALIZED="linux" ;;
esac

case "$(echo "${RUNNER_ARCH_RAW}" | tr '[:upper:]' '[:lower:]')" in
    x64) RUNNER_ARCH_NORMALIZED="amd64" ;;
    arm64) RUNNER_ARCH_NORMALIZED="arm64" ;;
    x86) RUNNER_ARCH_NORMALIZED="386" ;;
    *) RUNNER_ARCH_NORMALIZED="amd64" ;;
esac

# Extract PR number (only set for pull_request events)
PR_NUMBER=""
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${GITHUB_EVENT_NAME:-}" = "pull_request_target" ]; then
    if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
        PR_NUMBER=$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH}" 2>/dev/null || echo "")
    fi
fi

# Build the init request body
init_body=$(jq -n \
    --arg commit_sha "${COMMIT_SHA}" \
    --arg branch "${BRANCH}" \
    --arg pr_number "${PR_NUMBER}" \
    --arg trigger_type "${TRIGGER_TYPE}" \
    --arg runner_os "${RUNNER_OS_NORMALIZED}" \
    --arg runner_arch "${RUNNER_ARCH_NORMALIZED}" \
    '{
        commit_sha: $commit_sha,
        branch: $branch,
        pr_number: (if $pr_number == "" then null else ($pr_number | tonumber) end),
        trigger_type: $trigger_type,
        runner_info: {
            os: $runner_os,
            arch: $runner_arch
        }
    }')

info "Sending init request to ${CYCLOPT_API_URL}/bundler/runs/init"

init_response=$(curl -s -w "\n%{http_code}" \
    --max-time 300 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-access-cyclopt-token: ${CYCLOPT_TOKEN}" \
    -d "${init_body}" \
    "${CYCLOPT_API_URL}/bundler/runs/init") || {
    error "Failed to connect to Cyclopt backend at ${CYCLOPT_API_URL}"
    error "Check your network connectivity and cyclopt-api-url input."
    exit 1
}

# Split response body and HTTP status code
init_http_code=$(echo "${init_response}" | tail -n1)
init_body_response=$(echo "${init_response}" | sed '$d')

if [ "${init_http_code}" != "200" ] && [ "${init_http_code}" != "201" ]; then
    error "Backend returned HTTP ${init_http_code} during run initialization"
    error "Response: ${init_body_response}"

    case "${init_http_code}" in
        401) error "Authentication failed. Check that your CYCLOPT_API_TOKEN secret is valid." ;;
        403) error "Access denied. Your token may not have permission for this project." ;;
        422) error "Invalid request. Check your action inputs." ;;
        5*)  error "Cyclopt backend error. Please try again or contact support." ;;
    esac

    exit 1
fi

# Parse the init response
RUN_ID=$(echo "${init_body_response}" | jq -r '.runId // empty')
BINARY_DOWNLOAD_URL=$(echo "${init_body_response}" | jq -r '.binaryUrl // empty')
EXECUTION_TOKEN=$(echo "${init_body_response}" | jq -r '.executionToken // empty')

if [ -z "${RUN_ID}" ] || [ -z "${BINARY_DOWNLOAD_URL}" ] || [ -z "${EXECUTION_TOKEN}" ]; then
    error "Invalid init response from backend. Missing required fields."
    error "Response: ${init_body_response}"
    exit 1
fi

# Mask the execution token
echo "::add-mask::${EXECUTION_TOKEN}"

info "Run initialized: ${RUN_ID}"
endlog

# ---------------------------------------------------------------------------
# Step 3: Download the compiled runner binary
# ---------------------------------------------------------------------------
log "Downloading runner binary"

# If the binary URL is relative, prepend the API URL
if [[ "${BINARY_DOWNLOAD_URL}" == /* ]]; then
    BINARY_DOWNLOAD_URL="${CYCLOPT_API_URL}${BINARY_DOWNLOAD_URL}"
fi

info "Downloading from ${BINARY_DOWNLOAD_URL}"

download_http_code=$(curl -s -o "${BINARY_PATH}" -w "%{http_code}" \
    --max-time 120 \
    -H "x-access-cyclopt-token: ${CYCLOPT_TOKEN}" \
    "${BINARY_DOWNLOAD_URL}") || {
    error "Failed to download runner binary from ${BINARY_DOWNLOAD_URL}"
    exit 1
}

if [ "${download_http_code}" != "200" ]; then
    error "Failed to download runner binary. HTTP ${download_http_code}"
    rm -f "${BINARY_PATH}"
    exit 1
fi

# Verify the binary was downloaded and is not empty
if [ ! -s "${BINARY_PATH}" ]; then
    error "Downloaded binary is empty."
    exit 1
fi

chmod +x "${BINARY_PATH}"
binary_size=$(stat -f%z "${BINARY_PATH}" 2>/dev/null || stat -c%s "${BINARY_PATH}" 2>/dev/null || echo "unknown")
info "Binary downloaded successfully (${binary_size} bytes)"
endlog

# ---------------------------------------------------------------------------
# Step 4: Execute the runner binary
# ---------------------------------------------------------------------------
log "Running performance tests"

info "Executing: ${BINARY_PATH} --target-url ${TARGET_URL} --token [MASKED] --health-check-path ${HEALTH_CHECK_PATH}"

set +e
CYCLOPT_API_TOKEN="${CYCLOPT_TOKEN}" "${BINARY_PATH}" \
    --target-url "${TARGET_URL}" \
    --token "${EXECUTION_TOKEN}" \
    --health-check-path "${HEALTH_CHECK_PATH}"
RUNNER_EXIT_CODE=$?
set -e

if [ "${RUNNER_EXIT_CODE}" -eq 0 ]; then
    info "Performance tests completed successfully"
else
    warn "Performance tests completed with exit code ${RUNNER_EXIT_CODE}"
fi

endlog

# ---------------------------------------------------------------------------
# Step 5: Fetch formatted results from the backend
# ---------------------------------------------------------------------------
log "Fetching results"

# Allow a brief moment for the backend to process results
sleep 2

results_response=$(curl -s -w "\n%{http_code}" \
    --max-time 30 \
    -H "x-access-cyclopt-token: ${CYCLOPT_TOKEN}" \
    "${CYCLOPT_API_URL}/bundler/runs/results/${RUN_ID}") || {
    warn "Failed to fetch formatted results from backend. Skipping PR comment."
    results_response=""
}

VERDICT=""
SUMMARY=""
DASHBOARD_URL=""
THRESHOLD_RESULTS=""

if [ -n "${results_response}" ]; then
    results_http_code=$(echo "${results_response}" | tail -n1)
    results_body=$(echo "${results_response}" | sed '$d')

    if [ "${results_http_code}" = "200" ]; then
        VERDICT=$(echo "${results_body}" | jq -r '.verdict // empty')
        SUMMARY=$(echo "${results_body}" | jq -r '.summary // empty')
        DASHBOARD_URL=$(echo "${results_body}" | jq -r '.dashboard_url // empty')
        THRESHOLD_RESULTS=$(echo "${results_body}" | jq -r '.threshold_results // empty')

        info "Verdict: ${VERDICT}"
        if [ -n "${DASHBOARD_URL}" ]; then
            info "Dashboard: ${DASHBOARD_URL}"
        fi
    else
        warn "Backend returned HTTP ${results_http_code} when fetching results. Skipping PR comment."
    fi
fi

endlog

# ---------------------------------------------------------------------------
# Step 6: Set outputs
# ---------------------------------------------------------------------------
# Set GitHub Action outputs
echo "verdict=${VERDICT}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "run-id=${RUN_ID}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "dashboard-url=${DASHBOARD_URL}" >> "${GITHUB_OUTPUT:-/dev/null}"

# ---------------------------------------------------------------------------
# Step 7: Post PR comment (only for pull request events)
# ---------------------------------------------------------------------------
if [ -n "${PR_NUMBER}" ] && [ -n "${VERDICT}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    log "Posting PR comment"

    # Build the verdict header
    if [ "${VERDICT}" = "pass" ]; then
        VERDICT_EMOJI="white_check_mark"
        VERDICT_TEXT="Passed"
    else
        VERDICT_EMOJI="x"
        VERDICT_TEXT="Failed"
    fi

    # Build threshold results table
    THRESHOLD_TABLE=""
    if [ -n "${THRESHOLD_RESULTS}" ] && [ "${THRESHOLD_RESULTS}" != "null" ] && [ "${THRESHOLD_RESULTS}" != "[]" ]; then
        THRESHOLD_TABLE="### Threshold Results

| Metric | Threshold | Actual | Status |
|--------|-----------|--------|--------|
"
        THRESHOLD_TABLE+=$(echo "${THRESHOLD_RESULTS}" | jq -r '.[] |
            "| " + (.metric // "-") +
            " | " + (.threshold // "-") +
            " | " + (.actual // "-") +
            " | " + (if .passed then ":white_check_mark:" else ":x:" end) +
            " |"' 2>/dev/null || echo "")
    fi

    DASHBOARD_SECTION=""
    if [ -n "${DASHBOARD_URL}" ]; then
        DASHBOARD_SECTION=":bar_chart: [View full results on Cyclopt Dashboard](${DASHBOARD_URL})"
    fi

    # Build the full comment body
    COMMENT_MARKER="<!-- cyclopt-performance-results -->"

    COMMENT_BODY="${COMMENT_MARKER}
## :${VERDICT_EMOJI}: Cyclopt Performance Tests ${VERDICT_TEXT}

${SUMMARY:-No summary available.}

${THRESHOLD_TABLE}

---

${DASHBOARD_SECTION}

<sub>Commit: \`${COMMIT_SHA:0:7}\` | Run: \`${RUN_ID}\`</sub>"

    # Determine the repo for the GitHub API
    REPO="${GITHUB_REPOSITORY:?'GITHUB_REPOSITORY is not set'}"

    # Check if a previous Cyclopt comment exists
    existing_comment_id=$(curl -s \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" \
        | jq -r ".[] | select(.body | startswith(\"${COMMENT_MARKER}\")) | .id" \
        | head -n1) || existing_comment_id=""

    if [ -n "${existing_comment_id}" ] && [ "${existing_comment_id}" != "null" ]; then
        # Update existing comment
        info "Updating existing PR comment (ID: ${existing_comment_id})"
        curl -s -o /dev/null \
            -X PATCH \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.v3+json" \
            -d "$(jq -n --arg body "${COMMENT_BODY}" '{body: $body}')" \
            "https://api.github.com/repos/${REPO}/issues/comments/${existing_comment_id}" || {
            warn "Failed to update PR comment."
        }
    else
        # Create new comment
        info "Posting new PR comment"
        curl -s -o /dev/null \
            -X POST \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.v3+json" \
            -d "$(jq -n --arg body "${COMMENT_BODY}" '{body: $body}')" \
            "https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments" || {
            warn "Failed to post PR comment."
        }
    fi

    info "PR comment posted successfully"
    endlog
fi

# ---------------------------------------------------------------------------
# Step 8: Set check status and exit
# ---------------------------------------------------------------------------
if [ "${RUNNER_EXIT_CODE}" -ne 0 ]; then
    error "Performance tests failed (exit code: ${RUNNER_EXIT_CODE})"
fi

exit "${RUNNER_EXIT_CODE}"
