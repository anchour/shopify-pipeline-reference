# Shopify CI/CD pipeline reference

A working reference implementation of a Shopify theme deployment pipeline on
GitHub Actions. The theme here is [Dawn](https://github.com/Shopify/dawn),
unmodified and used only as a subject. **The workflows are the artifact.**

It exists so the pipeline design can be reviewed as something running rather
than something described, and so it can be rehearsed against a disposable
development store before being applied to a production storefront.

## What it does

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `ci.yml` | Pull request, push to `main`/`develop` | Theme Check and linting. These are the required checks. |
| `preview.yml` | Pull request opened or updated | Creates an unpublished preview theme, posts storefront and editor links |
| `preview-cleanup.yml` | Pull request closed | Deletes the preview theme |
| `deploy.yml` | Merge to `main`, or manual | Captures a rollback theme, checks for drift, publishes, notifies Slack |

`scripts/apply-branch-protection.sh` applies the protection model and hardens
Actions permissions. It takes the repository as an argument, so the same script
configures the rehearsal repo and the production one.

## Design decisions

**Previews are per pull request, not per branch.** A pull request has a close
event; a branch does not. Without one, every abandoned branch strands a theme
against the store's theme limit. Previews are automatic with a `skip-preview`
opt-out: forgetting a label should cost a wasted preview, not leave a reviewer
with nothing to look at.

**A rollback theme is captured before every deploy.** Publishing a different
theme in Shopify severs the GitHub connection on the theme that was live, so
recovery is a documented multi-step process. Capturing a known-good copy first
makes rollback "publish this theme" instead of "reconstruct the last good state
under pressure."

**Live content drift is reported, never silently resolved.** Merchandisers edit
content in the Shopify admin and those edits do not exist in the repository. A
deploy that quietly overwrites them destroys someone's work with no error and no
log line. This pipeline detects the difference and reports which files diverged.

**Failures are loud.** The Slack step fails the job if Slack rejects the payload,
and notifies on failure as well as success. A deploy that works is not news; a
deploy that half-completed needs to reach someone within minutes.

**Least privilege throughout.** Every workflow declares only the permissions it
needs. The default repository token is read-only, and GitHub Actions cannot
approve pull requests, so an approval requirement cannot be satisfied by
automation.

**CI never runs untrusted code with access to secrets.** Checks run on
`pull_request`, not `pull_request_target`. The latter, combined with checking out
pull-request head code, is a well-documented way to leak repository secrets to a
fork.

**Third-party actions are pinned to commit SHAs**, and the Shopify CLI version is
declared once as a repository variable so a single pipeline cannot run two
different Theme Check rule sets.

## Configuration

| Name | Type | Value |
| --- | --- | --- |
| `SHOPIFY_CLI_THEME_TOKEN` | secret | Theme Access token (`shptka_…`) |
| `SLACK_WEBHOOK_URL` | secret | Slack incoming webhook URL |
| `SHOPIFY_STORE` | variable | `your-store.myshopify.com` |
| `SHOPIFY_CLI_VERSION` | variable | Optional. Defaults to `3.91.0`. |

The Theme Access token comes from Shopify's first-party
[Theme Access](https://apps.shopify.com/theme-access) app, which scopes a
credential to themes only rather than requiring a staff account or a custom app
with broad API access.

For Slack, `docs/slack-app-manifest.yml` creates an app requesting exactly one
scope, `incoming-webhook`. It can post to a single channel and cannot read
messages, list channels, or see user data.

## Branch protection

```
./scripts/apply-branch-protection.sh owner/repo
```

Protects `main` and `develop`: pull request required, one approving review,
stale reviews dismissed on push, approval required from someone other than the
last pusher, required status checks, no force pushes, no deletion.

Machine branches are deliberately left unprotected. Where Shopify's app writes
merchandiser changes back to a connected branch and a release workflow recreates
a build branch, blanket protection across all branches breaks the pipeline.
Protect the branches humans merge into; leave the machine branches writable.

Note: on GitHub Free, rulesets require a public repository.

## Theme licence

Dawn is MIT licensed by Shopify. See `LICENSE.md`.
