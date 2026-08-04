# Acceptance walkthrough

A scripted end-to-end exercise of the pipeline. Roughly 15 minutes.

Run it as a sanity check after any change to the workflows, and as the
demonstration that closes out the pipeline work. Every step has a stated
expected result, so "it works" is something observed rather than asserted.

## Before starting

Confirm a clean baseline. All three should be true:

- No open pull requests labelled `live-data`
- The last deploy run succeeded
- `main` and `main-live` agree on theme files

```bash
gh pr list --repo <owner>/<repo> --label live-data --state open
gh run list --repo <owner>/<repo> --workflow=deploy.yml --limit 1
git fetch origin && git diff --name-only origin/main origin/main-live -- \
  assets blocks config layout locales sections snippets templates
```

The third command printing nothing is the pass condition.

---

## Part 1: A developer change

Proves preview environments, required checks, and the approval gate.

### 1.1 Open a pull request

Branch from `main`, make a small visible change to a Liquid file, push, and open
a pull request against `main`.

**Expect within about a minute:**

- Three checks start: `CI / Theme Check`, `CI / Lint`, `Preview / Preview Theme`
- A fourth, `Drift check`, also runs
- A comment appears with a storefront link and a theme editor link
- A comment appears confirming live content is in sync

Open the storefront link. The change should be visible on a theme that is not
published.

In the Shopify admin, under Online Store then Themes, a new unpublished theme
appears named `[prefix] PR #<number>`.

### 1.2 Try to merge without approval

Scroll to the merge box.

**Expect:**

- "Review required" with a red mark
- "All checks have passed", three of them, two badged `Required`
- The merge button greyed out

This is the gate. Checks passing is not sufficient; a human has to approve.

### 1.3 Approve, from a second account

Have someone else approve. The author cannot self-approve, and even with an
approval the last person to push is not allowed to be the approver.

**Expect:** merge button turns green.

If the branch was created before the most recent change to `main`, an
"out-of-date with the base branch" notice appears first. Click **Update branch**.
This is deliberate: it prevents checks passing against a stale base.

### 1.4 Merge

**Expect:**

- Preview theme deleted automatically, confirmed by a comment
- The theme disappears from the Shopify admin
- Deploy runs: gate passes, build runs if the theme has one, push to the live
  branch
- Slack receives a green "Deploy succeeded" message

Confirm the change is live on the storefront.

---

## Part 2: A merchandiser change

Proves the write-back loop, which is what stops content being destroyed.

### 2.1 Edit the theme in the Shopify admin

Online Store, Themes, Customize on the **published** theme. Change something
visible, for example a heading or a colour. Save.

**Expect within a minute or two:**

- A commit appears on the live branch authored by `shopify[bot]`
- `Live writeback` runs
- A pull request opens titled "Merchandiser content from `main-live`", labelled
  `live-data`, containing only theme files

The pull request body explains that the deploy will refuse to run while it is
open.

### 2.2 Confirm the deploy is blocked

Open any other pull request, or re-run the deploy manually.

**Expect:**

- The deploy fails at "Check for unmerged live content"
- "Build and release" is skipped, so nothing is overwritten
- Slack receives an amber "Deploy blocked" message
- The run summary names the unreconciled files

This is the safety property. The pipeline refuses to release over content that
is not in the repository.

### 2.3 Confirm open pull requests are updated

Leave a pull request open and make a second theme editor change.

**Expect:** the drift comment on that open pull request updates in place, with a
new timestamp and file list. GitHub does not re-run pull request checks unless
the branch is pushed to, so this is what keeps a long-lived pull request honest.

### 2.4 Merge the write-back

Review and merge the `live-data` pull request.

**Expect:** the merchandiser change is now in `main`, and the deploy is unblocked.

### 2.5 Deploy

Merge any pull request, or dispatch the deploy manually.

**Expect:** it succeeds, and Slack receives a green message.

---

## Part 3: Rollback

Prove reverting works before needing it.

Revert the release commit on the live branch, or publish the snapshot theme
captured before the release.

**Expect:** Shopify applies the revert, and the storefront returns to its
previous state.

Worth rehearsing rather than assuming, because a revert restores code but does
not restore merchandiser content published between the deploy and the rollback.
Establish how that case is handled before it happens under pressure.

---

## What each part demonstrates

| Part | Obligation |
| --- | --- |
| 1.1 | Per-pull-request preview environments |
| 1.2, 1.3 | Required approvals, required status checks |
| 1.4 | Deploy notifications, restrictions on direct pushes |
| 2.1, 2.4 | Merchandiser content is preserved, not overwritten |
| 2.2 | The deploy will not silently destroy content |
| 2.3 | Drift information stays current on open work |
| 3 | Releases are reversible |

---

## If something does not behave as described

**Check which copy of the workflow actually ran.** Workflows triggered by a push
execute the version of the file on the branch being pushed to, not on `main`. A
workflow present only on `main` will never fire for a push to the live branch.

```bash
gh api "repos/<owner>/<repo>/contents/.github/workflows/<file>.yml?ref=<branch>"
```

This is the single most common cause of a workflow appearing not to run, and the
failure is silent.
