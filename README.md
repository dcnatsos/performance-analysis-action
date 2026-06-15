# Cyclopt Performance Action

> **Internal documentation** — this action is private and distributed to clients via repository access grants.

## Overview

A composite GitHub Action that orchestrates Cyclopt performance tests directly on the GitHub runner. This action is a thin wrapper: it downloads and executes a compiled runner binary produced by the Cyclopt backend, then reports results.

**The action does NOT run k6 directly.** The runner binary contains k6 and test scripts embedded at compile time.

## Architecture

```
Client Workflow
    |
    v
+-------------------+
| Cyclopt Action    |  <-- This repo
|                   |
| 1. Health check   |
| 2. Init run       |-----> POST /bundler/runs/init
| 3. Download binary|-----> GET  /bundler/runs/{id}/binary
| 4. Execute binary |-----> (binary handles k6 + results)
| 5. Fetch results  |-----> GET  /bundler/runs/results/{id}
| 6. PR comment     |-----> GitHub API
| 7. Cleanup        |
+-------------------+
```

## Usage

In the client's `.github/workflows/performance.yml`:

```yaml
name: Performance Tests

on:
  pull_request:
    branches: [main]

jobs:
  performance:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Start application
        run: |
          docker compose up -d
          # The action handles health check polling

      - name: Run Cyclopt Performance Tests
        uses: cyclopt/secure-execution-action@v1
        with:
          token: ${{ secrets.CYCLOPT_API_TOKEN }}
          target-url: http://localhost:8080
```

### With all options

```yaml
      - name: Run Cyclopt Performance Tests
        uses: cyclopt/secure-execution-action@v1
        with:
          token: ${{ secrets.CYCLOPT_API_TOKEN }}
          target-url: http://localhost:8080
          health-check-path: /api/health
          health-check-timeout: '120'
          cyclopt-api-url: https://server.cyclopt.com
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `token` | Yes | — | Cyclopt API token (from `${{ secrets.CYCLOPT_API_TOKEN }}`) |
| `target-url` | Yes | — | URL of the application under test |
| `health-check-path` | No | `/health` | Health check endpoint path |
| `health-check-timeout` | No | `60` | Health check timeout in seconds |
| `cyclopt-api-url` | No | `https://server.cyclopt.com` | Cyclopt backend API URL |

## Outputs

| Output | Description |
|--------|-------------|
| `verdict` | Test verdict: `pass` or `fail` |
| `run-id` | Cyclopt run ID for this execution |
| `dashboard-url` | URL to the full results dashboard |

### Using outputs

```yaml
      - name: Run Cyclopt Performance Tests
        id: cyclopt
        uses: cyclopt/secure-execution-action@v1
        with:
          token: ${{ secrets.CYCLOPT_API_TOKEN }}
          target-url: http://localhost:8080

      - name: Check results
        if: always()
        run: |
          echo "Verdict: ${{ steps.cyclopt.outputs.verdict }}"
          echo "Dashboard: ${{ steps.cyclopt.outputs.dashboard-url }}"
```

## Execution Flow

### 1. Health Check
Polls `{target-url}{health-check-path}` every 2 seconds until HTTP 200 is received, or the timeout is reached. Because this is a composite action, it runs on the same runner host as the client workflow, so `http://localhost:8080` reaches an app started by a previous workflow step.

### 2. Initialize Run
Sends project metadata (commit SHA, branch, PR number, runner info) to the Cyclopt backend. The backend:
- Validates the Cyclopt API token
- Generates k6 test scripts from the project configuration
- Compiles a runner binary with embedded k6 + scripts
- Returns a `runId`, `binaryUrl`, and one-time `executionToken`

### 3. Download Binary
Downloads the compiled runner binary from the backend. The binary is a single static Go executable (~69MB) containing everything needed to run the tests.

### 4. Execute Binary
Runs the binary with `--target-url`, `--token`, `--health-check-path`, and `CYCLOPT_API_TOKEN` in its environment. The binary internally:
- Validates the one-time token with the backend (with Ed25519 signature verification)
- Extracts embedded k6 and test scripts
- Runs k6 against the target URL
- Reports raw results to the backend
- Exits with code 0 (pass) or 1 (fail)

### 5. Fetch Results
Retrieves formatted results from the backend including verdict and threshold results.

### 6. PR Comment
If triggered by a pull request, posts (or updates) a comment with:
- Pass/fail verdict
- Threshold results table
- Link to the Cyclopt dashboard, when the backend returns one

### 7. Cleanup
Removes the downloaded binary and exits with the binary's exit code.

## Backend API Contract

### Endpoints called by this action

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/bundler/runs/init` | POST | `x-access-cyclopt-token` | Initialize a performance test run |
| `/bundler/runs/{runId}/binary` | GET | `x-access-cyclopt-token` | Download the compiled runner binary |
| `/bundler/runs/results/{runId}` | GET | `x-access-cyclopt-token` | Fetch formatted results |

### Endpoints called by the runner binary (NOT by this action)

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/bundler/runs/tokens/validate` | POST | `x-access-cyclopt-token` + `runToken` in body | Validate one-time execution token |
| `/bundler/runs/results` | POST | `x-access-cyclopt-token` + `runToken` in body | Submit raw k6 results |

### Init Request

```json
POST /bundler/runs/init
x-access-cyclopt-token: <CYCLOPT_API_TOKEN>

{
    "commit_sha": "abc123",
    "branch": "feature/my-branch",
    "pr_number": 42,
    "trigger_type": "pull_request",
    "runner_info": {
        "os": "linux",
        "arch": "amd64"
    }
}
```

### Init Response

```json
{
    "runId": "run_xxx",
    "binaryUrl": "https://server.cyclopt.com/bundler/runs/run_xxx/binary",
    "executionToken": "otp_xxx"
}
```

### Results Response

```json
GET /bundler/runs/results/{runId}
x-access-cyclopt-token: <CYCLOPT_API_TOKEN>

{
    "verdict": "pass",
    "summary": "All thresholds passed. P95 response time: 230ms.",
    "threshold_results": [
        {
            "metric": "http_req_duration (p95)",
            "threshold": "< 500ms",
            "actual": "230ms",
            "passed": true
        }
    ]
}
```

## PR Comment Format

The action posts a markdown comment on the PR:

```markdown
<!-- cyclopt-performance-results -->
## :white_check_mark: Cyclopt Performance Tests Passed

All thresholds passed. P95 response time: 230ms.

### Threshold Results

| Metric | Threshold | Actual | Status |
|--------|-----------|--------|--------|
| http_req_duration (p95) | < 500ms | 230ms | :white_check_mark: |
| http_req_failed | < 1% | 0.00% | :white_check_mark: |

---

<sub>Commit: `abc1234` | Run: `run_xxx`</sub>
```

If a previous Cyclopt comment exists on the PR, it is updated instead of creating a new one. The `<!-- cyclopt-performance-results -->` HTML comment is used as a marker to identify Cyclopt comments.

## Error Handling

| Failure Mode | Behavior |
|-------------|----------|
| Health check timeout | Fails with clear message showing the URL and timeout |
| Backend unreachable | Fails with connection error details |
| Invalid token (401) | Fails with auth error message |
| Access denied (403) | Fails with permission error message |
| Binary download failure | Fails with HTTP status details |
| Binary crash | Captures exit code, fetches results if available |
| Results fetch failure | Warns but does not fail the action (uses binary exit code) |
| PR comment failure | Warns but does not fail the action |

## Security

- The `CYCLOPT_API_TOKEN` passed through the `token` input is masked in logs via `::add-mask::`
- The one-time `executionToken` is also masked
- The runner binary handles all cryptographic verification (Ed25519 signatures)
- No test scripts or k6 binaries are stored on the runner — everything is embedded in the compiled binary
- Temp files are cleaned up on exit (including on signals)

## Development

### File Structure

```
secure-execution-action/
  action.yml          # GitHub Action metadata and inputs
  Dockerfile          # Legacy Docker action image; not used by the composite action
  entrypoint.sh       # All orchestration logic
  README.md           # This file
```

### Testing locally

```bash
# Simulate the action environment
export INPUT_TOKEN="test-token"
export INPUT_TARGET_URL="http://localhost:8080"
export INPUT_HEALTH_CHECK_PATH="/health"
export INPUT_HEALTH_CHECK_TIMEOUT="30"
export INPUT_CYCLOPT_API_URL="http://localhost:3000"
export GITHUB_SHA="abc123"
export GITHUB_REF_NAME="main"
export GITHUB_EVENT_NAME="push"
export GITHUB_OUTPUT="/tmp/github-output"
export RUNNER_OS="Linux"
export RUNNER_ARCH="X64"

touch /tmp/github-output
./entrypoint.sh
```

### Runner dependencies

The action runs on the host runner and requires `bash`, `curl`, and `jq`. GitHub-hosted `ubuntu-latest` runners include these tools.
