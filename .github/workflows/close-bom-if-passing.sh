#!/bin/bash
set -euo pipefail

# Exit early if this is not a Jenkins check that completed
if [[ "$(jq -r .check_run.name < "$GITHUB_EVENT_PATH")" != "Jenkins" ]]; then
  echo "Not a Jenkins check, exiting"
  exit 0
fi

if [[ "$(jq -r .check_run.status < "$GITHUB_EVENT_PATH")" != "completed" ]]; then
  echo "Check not completed, exiting"
  exit 0
fi

# Get commit SHA from the check run
check_run_sha="$(jq -r .check_run.head_sha < "$GITHUB_EVENT_PATH")"
check_run_conclusion="$(jq -r .check_run.conclusion < "$GITHUB_EVENT_PATH")"

echo "Processing Jenkins check for commit: $check_run_sha"
echo "Check conclusion: $check_run_conclusion"

# Get the PR associated with this commit
pr_data=$(gh api graphql -f query='
  query($owner: String!, $repo: String!, $sha: GitObjectID!) {
    repository(owner: $owner, name: $repo) {
      object(oid: $sha) {
        ... on Commit {
          associatedPullRequests(first: 1) {
            nodes {
              number
              headRefName
              isDraft
              headRefOid
            }
          }
        }
      }
    }
  }' -f owner="$GITHUB_REPOSITORY_OWNER" -f repo="${GITHUB_REPOSITORY#*/}" -f sha="$check_run_sha")

# Extract PR data
pr_number=$(echo "$pr_data" | jq -r '.data.repository.object.associatedPullRequests.nodes[0].number // empty')
pr_head_sha=$(echo "$pr_data" | jq -r '.data.repository.object.associatedPullRequests.nodes[0].headRefOid // empty')
pr_head_ref=$(echo "$pr_data" | jq -r '.data.repository.object.associatedPullRequests.nodes[0].headRefName // empty')

# Exit early if no associated PR found
if [[ -z "$pr_number" ]]; then
  echo "No associated pull request found for commit $check_run_sha, exiting"
  exit 0
fi

pr_draft=$(echo "$pr_data" | jq -r '.data.repository.object.associatedPullRequests.nodes[0].isDraft // empty')

echo "Head ref: $pr_head_ref"
echo "Draft: $pr_draft"

# Check if this is a Dependabot or Renovate PR for io.jenkins.tools.bom-bom-* dependencies
if [[ ! ("$pr_head_ref" =~ ^renovate/io\.jenkins\.tools\.bom-bom- || "$pr_head_ref" =~ ^dependabot/maven/io\.jenkins\.tools\.bom-bom-) ]]; then
  echo "Not a BOM dependency PR (head ref: $pr_head_ref), exiting"
  exit 0
fi

echo "Processing BOM dependency PR with head ref: $pr_head_ref"

# Verify commit matches the PR head
if [[ "$check_run_sha" != "$pr_head_sha" ]]; then
  echo "Head SHA mismatch (check: $check_run_sha, PR head: $pr_head_sha), exiting"
  exit 0
fi

# TODO verify that there is only commit in the PR (presumably from the bot) so we do not close PRs with manual changes

# Handle based on CI conclusion
if [[ "$check_run_conclusion" == "success" ]]; then
  echo "CI passed, closing PR #$pr_number"

  # Leave a comment and close the PR
  gh pr comment "$pr_number" --body "✅ CI passed successfully. Closing this PR." --repo "$GITHUB_REPOSITORY"
  gh pr close "$pr_number" --repo "$GITHUB_REPOSITORY"

  echo "PR #$pr_number closed due to successful CI"
else
  echo "CI failed with conclusion: $check_run_conclusion"

  # Leave a comment
  gh pr comment "$pr_number" --body "❌ CI failed with conclusion: \`$check_run_conclusion\`. Please investigate the failure." --repo "$GITHUB_REPOSITORY"

  # Convert from draft to ready for review if it's currently a draft
  if [[ "$pr_draft" == "true" ]]; then
    gh pr ready "$pr_number" --repo "$GITHUB_REPOSITORY"
    echo "PR #$pr_number converted from draft to ready for review"
  else
    echo "PR #$pr_number is already ready for review"
  fi
fi
