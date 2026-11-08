# Contributing to Media Harbor

## Report a problem

Open a GitHub issue with the app version and build from **About Media Harbor**, your macOS version, steps to reproduce, and the expected and actual results. For a site issue, include a public example URL if possible, whether sign-in is required, and the scan settings you used. Use an example that contains no private content or credentials. Remove cookies, authorization headers, and access tokens from any logs you share.

For a feature request, describe the workflow you want to complete and where the current app falls short. For a new site rule, include the hostname, an example page, and which media or next-page links the rule should select.

## Submit a change

1. Follow the [source build instructions](README.md#build-from-source) and make sure the app launches locally.
2. Create a branch for a focused change. Update the README or in-app Help if the workflow changes.
3. Build the app and exercise the affected workflow. For scanner changes, check both a successful scan and a page where the original media cannot be found. For download changes, check the queue state and saved output.
4. Open a pull request describing what changed, how you verified it, and any known limitations. Include a screenshot for visible interface changes when it helps reviewers.

Generated runtimes and local build products are excluded from Git. For dependency updates, include the revised pins and checksums. For FFmpeg updates, include the matching source and build inputs.
