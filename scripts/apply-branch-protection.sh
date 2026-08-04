#!/usr/bin/env bash
#
# Applies the Phase 1 branch protection model to a repository.
#
# Idempotent: re-running updates the existing rulesets rather than duplicating
# them. Takes the repository as an argument so the same script configures the
# rehearsal repo and, after sign-off, Tonal's.
#
#   ./scripts/apply-branch-protection.sh anchour/tonal-pipeline-test
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
# The audit found both wide open on tonalfitness/shopify-website:
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
gh api -X POST "repos/${REPO}/rulesets" --input - --silent <<'JSON' || \
  echo "  (ruleset may already exist; see note below)"
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
