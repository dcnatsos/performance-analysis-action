const core = require("@actions/core");
const exec = require("@actions/exec");
const github = require("@actions/github");
const fs = require("fs");
const path = require("path");
const { pipeline } = require("stream/promises");

// =============================================================================
// Cyclopt Performance Action
//
// Orchestrates the full performance test lifecycle:
//   1. Wait for the application to be healthy
//   2. Initialize a run with the Cyclopt backend
//   3. Download the compiled runner binary
//   4. Execute the binary (which runs k6 tests internally)
//   5. Fetch formatted results from the backend
//   6. Post a PR comment with results (if triggered by a PR)
//   7. Set outputs and exit status
// =============================================================================

const BINARY_PATH = "/tmp/cyclopt-runner";
const COMMENT_MARKER = "<!-- cyclopt-performance-results -->";

async function run() {
  let runnerExitCode = 0;

  try {
    // -----------------------------------------------------------------------
    // Step 1: Read inputs and mask secrets
    // -----------------------------------------------------------------------
    const token = core.getInput("token", { required: true });
    const targetUrl = core.getInput("target-url", { required: true });
    const healthCheckPath = core.getInput("health-check-path") || "/health";
    const healthCheckTimeout = parseInt(core.getInput("health-check-timeout") || "60", 10);
    let apiUrl = core.getInput("cyclopt-api-url") || "https://api.cyclopt.com";
    apiUrl = apiUrl.replace(/\/+$/, ""); // strip trailing slashes

    core.setSecret(token);

    // -----------------------------------------------------------------------
    // Step 2: Wait for the application to be healthy
    // -----------------------------------------------------------------------
    core.startGroup("Waiting for application health check");

    const healthUrl = `${targetUrl.replace(/\/+$/, "")}${healthCheckPath}`;
    core.info(`Polling ${healthUrl} (timeout: ${healthCheckTimeout}s)`);

    const healthy = await waitForHealth(healthUrl, healthCheckTimeout);
    if (!healthy.ok) {
      core.error(
        `Application health check failed. ${healthUrl} did not return HTTP 200 ` +
        `within ${healthCheckTimeout}s (last status: ${healthy.lastStatus})`
      );
      core.error("Make sure your application is running and the health check endpoint is correct.");
      process.exitCode = 1;
      return;
    }

    core.info(`Application is healthy (${healthy.elapsed}s elapsed)`);
    core.endGroup();

    // -----------------------------------------------------------------------
    // Step 3: Initialize run with the Cyclopt backend
    // -----------------------------------------------------------------------
    core.startGroup("Initializing Cyclopt run");

    const context = github.context;
    const prNumber = context.payload.pull_request?.number || null;

    const initBody = {
      commit_sha: context.sha || "unknown",
      branch: process.env.GITHUB_REF_NAME || "unknown",
      pr_number: prNumber,
      trigger_type: context.eventName || "unknown",
      runner_info: {
        os: process.env.RUNNER_OS || "unknown",
        arch: process.env.RUNNER_ARCH || "unknown",
      },
    };

    core.info(`Sending init request to ${apiUrl}/api/v1/runs/init`);

    const initResponse = await fetchWithTimeout(`${apiUrl}/api/v1/runs/init`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(initBody),
    }, 30_000);

    if (!initResponse.ok) {
      const errorBody = await initResponse.text().catch(() => "");
      core.error(`Backend returned HTTP ${initResponse.status} during run initialization`);
      core.error(`Response: ${errorBody}`);

      switch (initResponse.status) {
        case 401: core.error("Authentication failed. Check that your CYCLOPT_TOKEN is valid."); break;
        case 403: core.error("Access denied. Your token may not have permission for this project."); break;
        case 422: core.error("Invalid request. Check your action inputs."); break;
        default:
          if (initResponse.status >= 500) {
            core.error("Cyclopt backend error. Please try again or contact support.");
          }
      }

      process.exitCode = 1;
      return;
    }

    const initData = await initResponse.json();
    const { run_id: runId, binary_download_url: binaryDownloadUrl, execution_token: executionToken } = initData;

    if (!runId || !binaryDownloadUrl || !executionToken) {
      core.error("Invalid init response from backend. Missing required fields.");
      core.error(`Response: ${JSON.stringify(initData)}`);
      process.exitCode = 1;
      return;
    }

    core.setSecret(executionToken);
    core.info(`Run initialized: ${runId}`);
    core.endGroup();

    // -----------------------------------------------------------------------
    // Step 4: Download the compiled runner binary
    // -----------------------------------------------------------------------
    core.startGroup("Downloading runner binary");

    let fullBinaryUrl = binaryDownloadUrl;
    if (fullBinaryUrl.startsWith("/")) {
      fullBinaryUrl = `${apiUrl}${fullBinaryUrl}`;
    }

    core.info(`Downloading from ${fullBinaryUrl}`);

    const downloadResponse = await fetchWithTimeout(fullBinaryUrl, {
      headers: { Authorization: `Bearer ${token}` },
    }, 120_000);

    if (!downloadResponse.ok) {
      core.error(`Failed to download runner binary. HTTP ${downloadResponse.status}`);
      process.exitCode = 1;
      return;
    }

    await pipeline(downloadResponse.body, fs.createWriteStream(BINARY_PATH));
    fs.chmodSync(BINARY_PATH, 0o755);

    const binarySize = fs.statSync(BINARY_PATH).size;
    if (binarySize === 0) {
      core.error("Downloaded binary is empty.");
      process.exitCode = 1;
      return;
    }

    core.info(`Binary downloaded successfully (${binarySize} bytes)`);
    core.endGroup();

    // -----------------------------------------------------------------------
    // Step 5: Execute the runner binary
    // -----------------------------------------------------------------------
    core.startGroup("Running performance tests");

    core.info(
      `Executing: ${BINARY_PATH} --target-url ${targetUrl} --token [MASKED] --health-check-path ${healthCheckPath}`
    );

    runnerExitCode = await exec.exec(BINARY_PATH, [
      "--target-url", targetUrl,
      "--token", executionToken,
      "--health-check-path", healthCheckPath,
    ], { ignoreReturnCode: true });

    if (runnerExitCode === 0) {
      core.info("Performance tests completed successfully");
    } else {
      core.warning(`Performance tests completed with exit code ${runnerExitCode}`);
    }

    core.endGroup();

    // -----------------------------------------------------------------------
    // Step 6: Fetch formatted results from the backend
    // -----------------------------------------------------------------------
    core.startGroup("Fetching results");

    // Allow a brief moment for the backend to process results
    await sleep(2000);

    let verdict = "";
    let summary = "";
    let dashboardUrl = "";
    let thresholdResults = null;

    try {
      const resultsResponse = await fetchWithTimeout(
        `${apiUrl}/api/v1/runs/${runId}`,
        { headers: { Authorization: `Bearer ${token}` } },
        30_000
      );

      if (resultsResponse.ok) {
        const resultsData = await resultsResponse.json();
        verdict = resultsData.verdict || "";
        summary = resultsData.summary || "";
        dashboardUrl = resultsData.dashboard_url || "";
        thresholdResults = resultsData.threshold_results || null;

        core.info(`Verdict: ${verdict}`);
        core.info(`Dashboard: ${dashboardUrl}`);
      } else {
        core.warning(
          `Backend returned HTTP ${resultsResponse.status} when fetching results. Skipping PR comment.`
        );
      }
    } catch (err) {
      core.warning(`Failed to fetch formatted results from backend: ${err.message}. Skipping PR comment.`);
    }

    core.endGroup();

    // -----------------------------------------------------------------------
    // Step 7: Set outputs
    // -----------------------------------------------------------------------
    core.setOutput("verdict", verdict);
    core.setOutput("run-id", runId);
    core.setOutput("dashboard-url", dashboardUrl);

    // -----------------------------------------------------------------------
    // Step 8: Post PR comment (only for pull request events)
    // -----------------------------------------------------------------------
    const githubToken = process.env.GITHUB_TOKEN || "";
    if (prNumber && verdict && githubToken) {
      core.startGroup("Posting PR comment");

      try {
        await postPrComment({
          githubToken,
          repo: context.repo,
          prNumber,
          verdict,
          summary,
          dashboardUrl,
          thresholdResults,
          commitSha: context.sha,
          runId,
        });
        core.info("PR comment posted successfully");
      } catch (err) {
        core.warning(`Failed to post PR comment: ${err.message}`);
      }

      core.endGroup();
    }

    // -----------------------------------------------------------------------
    // Step 9: Set exit code
    // -----------------------------------------------------------------------
    if (runnerExitCode !== 0) {
      core.error(`Performance tests failed (exit code: ${runnerExitCode})`);
      process.exitCode = runnerExitCode;
    }
  } catch (err) {
    core.setFailed(`Unexpected error: ${err.message}`);
  } finally {
    // Cleanup
    core.info("Cleaning up...");
    try {
      fs.unlinkSync(BINARY_PATH);
    } catch {
      // Binary may not exist if we failed before downloading
    }
    core.info("Cleanup complete.");
  }
}

// =============================================================================
// Helpers
// =============================================================================

/**
 * Poll a URL until it returns HTTP 200, or timeout.
 */
async function waitForHealth(url, timeoutSeconds) {
  let elapsed = 0;
  let lastStatus = "000";

  while (elapsed < timeoutSeconds) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 5000);

      const response = await fetch(url, {
        signal: controller.signal,
        redirect: "follow",
      });
      clearTimeout(timer);

      lastStatus = String(response.status);
      if (response.status === 200) {
        return { ok: true, elapsed, lastStatus };
      }
    } catch {
      lastStatus = "000";
    }

    await sleep(2000);
    elapsed += 2;
  }

  return { ok: false, elapsed, lastStatus };
}

/**
 * fetch() with a timeout via AbortController.
 */
async function fetchWithTimeout(url, options = {}, timeoutMs = 30_000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(url, {
      ...options,
      signal: controller.signal,
    });
    return response;
  } catch (err) {
    if (err.name === "AbortError") {
      throw new Error(`Request to ${url} timed out after ${timeoutMs}ms`);
    }
    throw err;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Post or update a PR comment with performance test results.
 */
async function postPrComment({ githubToken, repo, prNumber, verdict, summary, dashboardUrl, thresholdResults, commitSha, runId }) {
  const octokit = github.getOctokit(githubToken);

  const verdictEmoji = verdict === "pass" ? "white_check_mark" : "x";
  const verdictText = verdict === "pass" ? "Passed" : "Failed";

  // Build threshold table
  let thresholdTable = "";
  if (Array.isArray(thresholdResults) && thresholdResults.length > 0) {
    const rows = thresholdResults.map((t) => {
      const status = t.passed ? ":white_check_mark:" : ":x:";
      return `| ${t.metric || "-"} | ${t.threshold || "-"} | ${t.actual || "-"} | ${status} |`;
    });

    thresholdTable = `### Threshold Results

| Metric | Threshold | Actual | Status |
|--------|-----------|--------|--------|
${rows.join("\n")}`;
  }

  const commentBody = `${COMMENT_MARKER}
## :${verdictEmoji}: Cyclopt Performance Tests ${verdictText}

${summary || "No summary available."}

${thresholdTable}

---

:bar_chart: [View full results on Cyclopt Dashboard](${dashboardUrl || "#"})

<sub>Commit: \`${(commitSha || "").substring(0, 7)}\` | Run: \`${runId}\`</sub>`;

  // Check for existing comment
  const { data: comments } = await octokit.rest.issues.listComments({
    ...repo,
    issue_number: prNumber,
    per_page: 100,
  });

  const existingComment = comments.find((c) => c.body?.startsWith(COMMENT_MARKER));

  if (existingComment) {
    core.info(`Updating existing PR comment (ID: ${existingComment.id})`);
    await octokit.rest.issues.updateComment({
      ...repo,
      comment_id: existingComment.id,
      body: commentBody,
    });
  } else {
    core.info("Posting new PR comment");
    await octokit.rest.issues.createComment({
      ...repo,
      issue_number: prNumber,
      body: commentBody,
    });
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Run the action
run();
