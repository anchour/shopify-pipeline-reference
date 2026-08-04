#!/usr/bin/env bash
#
# Applies the Phase 1 branch protection model to a repository.
#
# Idempotent: re-running updates the existing rulesets rather than duplicating
# them. Takes the repository as an argument so the same script configures the
# rehearsal repo and, after sign-off, the production one.
#
#   ./scripts/apply-branch-protection.sh owner/repo
#
# Requires: gh, authenticated, with admin on the target repository.

set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ]; then
  echo "Usage: $0 <owner/repo>" >&2
  exit 1
fi

echo "Applying branch protection to ${REPO}"
echo

# ── Repository-level Actions hardening ────────────────────────────────────────
#
# Two settings that undercut any approval requirement if left at their defaults.
# Both were found wide open on the audited repository:
#
#   default_workflow_permissions: write
#     Every job gets a write-scoped token whether it needs one or not.
#
#   can_approve_pull_request_reviews: true
#     Actions can approve pull requests. An approval gate that automation can
#     satisfy is not a gate.
#
echo "→ Hardening Actions permissions"
gh api -X PUT "repos/${REPO}/actions/permissions/workflow" \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false \
  --silent
echo "  default token: read, Actions self-approval: disabled"

# ── Protection for development branches ───────────────────────────────────────
#
# Applies to main and develop. Required checks are the two verified in the audit
# as passing today. Cypress is deliberately absent: it cannot currently run
# without a preview URL and a storefront password, and a required check that
# never reports blocks every pull request permanently.
#
echo "→ Protecting main and develop"

# Distinguish the failure modes rather than treating every non-zero exit as
# "already exists". A 403 means the plan does not allow rulesets on a private
# repository; a 422 means the ruleset is already there. Reporting both as the
# latter is the same silent-failure pattern this pipeline exists to remove.
RULESET_OUT=$(mktemp)
if gh api -X POST "repos/${REPO}/rulesets" --input - >"$RULESET_OUT" 2>&1 <<'JSON'
{
  "name": "Protected development branches",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main", "refs/heads/develop"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": true,
        "required_review_thread_resolution": false,
        "automatic_copilot_code_review_enabled": false,
        "allowed_merge_methods": ["squash", "merge"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "Theme Check" },
          { "context": "Lint" }
        ]
      }
    }
  ]
}
JSON
then
  echo "  ruleset applied"
else
  if grep -q 'Upgrade to GitHub Pro' "$RULESET_OUT"; then
    echo "  FAILED: rulesets on a private repository require GitHub Pro or Team." >&2
    echo "          Make the repository public, or upgrade the plan." >&2
    rm -f "$RULESET_OUT"
    exit 1
  elif grep -qi 'already exists\|name.*taken' "$RULESET_OUT"; then
    echo "  ruleset already exists; leaving it unchanged (see note below)"
  else
    echo "  FAILED:" >&2
    cat "$RULESET_OUT" >&2
    rm -f "$RULESET_OUT"
    exit 1
  fi
fi
rm -f "$RULESET_OUT"

# ── Machine branches ──────────────────────────────────────────────────────────
#
# Deliberately NOT protected.
#
# In the production topology, Shopify's own app pushes merchandiser changes
# directly to the connected live branch, and the release workflow force-recreates
# the built branch on every run. Blanket protection across all branches breaks
# both. This is the carve-out the audit flagged as blocker 4: protect the
# branches humans merge into, leave the machine branches writable.
#
echo "→ Machine branches (main-live, main-built, main-live-data): intentionally unprotected"

echo
echo "Done. Current state:"
gh api "repos/${REPO}/rulesets" --jq '.[] | "  ruleset: \(.name) [\(.enforcement)]"'
gh api "repos/${REPO}/actions/permissions/workflow" \
  --jq '"  default_workflow_permissions: \(.default_workflow_permissions)\n  can_approve_pull_request_reviews: \(.can_approve_pull_request_reviews)"'

cat <<'NOTE'

Note on re-runs
  Creating a ruleset that already exists returns 422. To update instead:
    gh api repos/<owner>/<repo>/rulesets --jq '.[] | "\(.id) \(.name)"'
    gh api -X PUT repos/<owner>/<repo>/rulesets/<id> --input <payload>
NOTE
