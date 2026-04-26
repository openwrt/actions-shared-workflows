# LLM PR review — setup

Per-PR and nightly LLM-driven code review for OpenWrt repositories. Powered
by Claude Code routines fired over their HTTP API from GitHub Actions, so
forked-PR review works without exposing repo secrets to fork workflows.

## Architecture

Two routines per consumer repository:

- **PR review routine** — fired by `pull_request_target: [opened, reopened]`.
  Posts a single GitHub PR review with a 1–2 sentence summary, optional
  commit-vs-message checks, and inline line-anchored comments for issues.
- **Nightly digest routine** — fired by an Actions cron at 03:00 UTC. Walks
  open PRs that have new commits since the last bot review and posts a new
  review covering only the newly-added commits. Workflow skips the API fire
  entirely when no PR has changed, so quiet nights cost nothing.

Two reusable workflows live in this repository
(`openwrt/actions-shared-workflows`):

- `.github/workflows/reusable_llm-pr-review.yml`
- `.github/workflows/reusable_llm-nightly-digest.yml`

Each consumer repo (`openwrt`, `luci`, `netifd`, …) ships a thin
`.github/workflows/llm-review.yml` wrapper that calls the reusable workflows.

## Cap math

Routine `/fire` calls count against a per-account daily routine cap. With
this design:

- 1 fire per opened/reopened PR
- At most 1 fire per night (skipped when no PR has new commits)
- Re-pushes do not fire — they are picked up by the next nightly digest

Effective new-PR fires per day: cap minus 1 (for the nightly).

## One-time bot setup

Done once for the entire OpenWrt org, not per repo.

1. Use the dedicated bot GitHub account `openwrt-ai`.
2. Sign in to https://claude.ai as `openwrt-ai` and link the GitHub identity.
3. Install the Claude GitHub App on the `openwrt-ai` account, scoped to the
   consumer repos that will use the review.

No special repo role is required: posting PR reviews and inline comments
works for any GitHub user on a public repository.

## Per-repo routine creation

Done twice per consumer repo (once for the PR routine, once for the nightly
routine), as `openwrt-ai` at https://claude.ai/code/routines.

For each routine:

1. **New routine.** Name it `<repo>-llm-pr-review` or
   `<repo>-llm-nightly-digest` (e.g. `openwrt-llm-pr-review`).
2. **Prompt.** Copy the corresponding prompt from this repo:
   - `llm-review-prompts/llm-pr-review.md`
   - `llm-review-prompts/llm-nightly-digest.md`
3. **Repository.** Attach only the consumer repo. Leave
   *Allow unrestricted branch pushes* OFF.
4. **Connectors.** Trim to GitHub only. Disable Gmail, Drive, Calendar, etc.
5. **Model.** Sonnet 4.6 is a reasonable default. Switch to Opus 4.7 if
   reviews feel underpowered for the repo.
6. **Trigger.** Add an **API** trigger. Click **Generate token** — the token
   is shown once. Copy it directly into the consumer repo's secret
   (see next section). Note the routine ID (`trig_...`) — this goes into a
   variable.

## Per-repo GitHub configuration

In each consumer repo's *Settings → Secrets and variables → Actions*:

| Name                          | Type     | Value                                  |
| ----------------------------- | -------- | -------------------------------------- |
| `LLM_ROUTINE_ID_PR`           | variable | `trig_...` ID of the PR review routine |
| `LLM_ROUTINE_TOKEN_PR`        | secret   | Bearer token for the PR review routine |
| `LLM_ROUTINE_ID_NIGHTLY`      | variable | `trig_...` ID of the nightly routine   |
| `LLM_ROUTINE_TOKEN_NIGHTLY`   | secret   | Bearer token for the nightly routine   |

Then drop the consumer wrapper into the repo at
`.github/workflows/llm-review.yml`. A template is in `openwrt/openwrt`'s
copy of this file; the basic shape is:

```yaml
name: LLM Review

on:
  pull_request_target:
    types: [opened, reopened]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:

permissions: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || 'nightly' }}
  cancel-in-progress: false

jobs:
  pr-review:
    if: github.event_name == 'pull_request_target' && github.repository_owner == 'openwrt'
    permissions: {}
    uses: openwrt/actions-shared-workflows/.github/workflows/reusable_llm-pr-review.yml@main
    with:
      routine_id: ${{ vars.LLM_ROUTINE_ID_PR }}
      # extra_repos: gregkh/linux:v6.18.21
    secrets:
      llm_routine_token: ${{ secrets.LLM_ROUTINE_TOKEN_PR }}

  nightly:
    if: (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch') && github.repository_owner == 'openwrt'
    permissions:
      pull-requests: read
    uses: openwrt/actions-shared-workflows/.github/workflows/reusable_llm-nightly-digest.yml@main
    with:
      routine_id: ${{ vars.LLM_ROUTINE_ID_NIGHTLY }}
      # extra_repos: gregkh/linux:v6.18.21
    secrets:
      llm_routine_token: ${{ secrets.LLM_ROUTINE_TOKEN_NIGHTLY }}
```

## Per-repo project rules (optional)

Drop a `.github/llm-review-rules.md` file into the consumer repo to teach
the routine project-specific patterns to flag. The routine reads it at
session start. Typical content: deprecated bindings the project is
migrating away from, where in-tree neighbours still use the old form.
See `openwrt/openwrt/.github/llm-review-rules.md` for an example.

## Customising per repo

Reusable workflow inputs:

| Input         | Default          | Notes                                                                                    |
| ------------- | ---------------- | ---------------------------------------------------------------------------------------- |
| `routine_id`  | required         | The `trig_...` ID for that routine.                                                      |
| `extra_repos` | `''`             | Comma-separated entries, each either `owner/name:ref` or a full `http(s)://host/path[.git]:ref` (e.g. `gregkh/linux:v6.18.21,https://thekelleys.org.uk/git/dnsmasq.git:master`). The ref is required and is checked out as a shallow clone. The routine inspects the PR and only consults the entries it actually needs. |
| `max_prs`     | `16` (nightly)   | Upper bound on PRs per nightly session.                                                  |
| `bot_user`    | `openwrt-ai`     | Nightly digest only. Used to identify the bot's own previous reviews.                    |

`extra_repos` is a *list of repos the routine may clone if relevant*.
Each entry takes one of two forms:

- `owner/name:ref` — GitHub shorthand, expanded to `https://github.com/owner/name`.
- `http(s)://host/path[.git]:ref` — any other public HTTPS git remote
  (e.g. `https://thekelleys.org.uk/git/dnsmasq.git:master`,
  `https://git.w1.fi/hostap.git:main`).

The ref (tag or branch) is required and is checked out as a shallow
clone. The routine itself decides whether each entry is needed based
on the PR's changed files, so it is safe to list reference repos you
only sometimes need (for example, the Linux stable tree at a specific
kernel version). The same repo may appear at several refs — entries
land in distinct directories keyed by the ref, and the routine picks
the version that matches the PR.

For `openwrt/openwrt`, the consumer wrapper computes `extra_repos`
dynamically by reading the `target/linux/generic/kernel-*` files in the
base branch, so the kernel version is always current. Other consumer repos
can either pass a static `extra_repos` value or add a similar pre-step.

Cron time can be changed in the consumer wrapper. Default 03:00 UTC.

## Verifying

1. Open a small test PR. Within ~1 minute, the PR-review routine should fire
   and a review should appear.
2. Manually trigger the nightly: *Actions → LLM Review → Run workflow*.
   This dispatches via `workflow_dispatch`. Watch the live session via the
   URL printed in the routine UI.

## Operations

- **View routine runs.** https://claude.ai/code/routines → routine →
  *Past runs*. Each run opens as a full session with all tool calls visible.
- **Live monitoring.** The `/fire` API response includes a session URL.
  Open it in a browser to watch the run in real time.
- **Token rotation.** In the routine UI, click *Regenerate* on the API
  trigger. Copy the new token into the corresponding repo secret.
- **Pause reviews.** Either disable the workflow file in the consumer repo
  or revoke the trigger token in the routine UI.
- **Daily cap exhausted.** The reusable workflow's `curl` will fail with a
  non-2xx response and the workflow will report failure. The PR is silently
  unreviewed; the next nightly digest will pick it up.

## Troubleshooting

- **`curl` returns 401.** Token is wrong or revoked. Regenerate.
- **`curl` returns 404.** Routine ID is wrong, or the routine has been
  deleted. Check `LLM_ROUTINE_ID_*` variables.
- **Nightly job runs but no review appears.** Open the session URL from the
  routine's *Past runs* page. Common causes: PR has been merged/closed, or
  the routine prompt judged the PR up-to-date and exited.
- **Routine clones the wrong tree.** Only the consumer repo is cloned by the
  routine itself; everything else is `git clone` from inside the prompt and
  uses public HTTPS. Check that the `extra_repos` argument actually lists
  the repo you wanted.
