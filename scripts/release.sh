#!/usr/bin/env bash
#
# Cut a new dated release of the Electron app: bump the version, sync the
# lockfile, tag, snapshot the source to the public mirror, merge it, and
# publish the release there.
#
#   scripts/release.sh
#
# Must be run from a clean `main`, even with origin/main. Prompts once, up
# front, for release notes -- type them (point-form, one per line) and finish
# with Ctrl-D, or pipe them in. Everything after that is unattended: version
# bump -> commit -> tag -> push -> mirror snapshot -> merge -> mirror release
# -> wait for the dmg build.
#
# This automates .claude/skills/create-release/SKILL.md's steps exactly; that
# file is the design doc, this is the implementation. The one thing left to
# judgment is what the notes say -- drafting them (from `git log
# <prev-tag>..HEAD`) is not this script's job, whether a human or an agent is
# on the other end of the prompt.

set -euo pipefail

PUBLIC_REPO="${PUBLIC_REPO:-hrusoft/tabs}"
ROOT="$(git rev-parse --show-toplevel)"

die()  { printf 'release: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

cd "$ROOT"

# ---- preflight -----------------------------------------------------------

branch="$(git branch --show-current)"
[ "$branch" = "main" ] || die "on '$branch', not main -- releases are cut from main"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty -- commit or stash first"

git fetch origin main --quiet
local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse origin/main)"
[ "$local_head" = "$remote_head" ] \
  || die "local main ($local_head) is not even with origin/main ($remote_head) -- pull or push first"

prev_tag="$(git tag --list 'v*' --sort=-version:refname | head -1)"
[ -n "$prev_tag" ] || die "no previous v* tag found to diff release notes against"

# A plain YYYY.MM.DD tag, unless one already exists (here or on the mirror) --
# then fall back to a YYYY.MM.DD.HHMM tag so a second release the same day
# doesn't collide with the first.
tag_taken() {
  git rev-parse --quiet --verify "refs/tags/$1" >/dev/null 2>&1 \
    || gh release view "$1" --repo "$PUBLIC_REPO" >/dev/null 2>&1
}

date_str="$(date +%Y.%m.%d)"
tag="v$date_str"
if tag_taken "$tag"; then
  date_str="$(date +%Y.%m.%d.%H%M)"
  tag="v$date_str"
  tag_taken "$tag" && die "tag $tag already exists -- already released this minute?"
fi

sync_status="$("$ROOT/scripts/sync-public.sh" status)"
printf '%s\n' "$sync_status" >&2
if grep -q 'commit(s) on main to import' <<<"$sync_status"; then
  die "$PUBLIC_REPO has commits this repository doesn't -- port them first, or see sync-public.sh --allow-revert"
fi

# ---- release notes -------------------------------------------------------

note ""
note "commits since $prev_tag:"
git log "$prev_tag"..HEAD --oneline | sed 's/^/  /' >&2
note ""
note "enter release notes as plain-language bullets, e.g.:"
note "  - Fix focus outline clipping on nested tab leaves"
note "finish with Ctrl-D (or EOF if this is piped in):"
notes="$(cat)"
[ -n "$notes" ] || die "empty release notes -- aborting before anything changed"

# ---- bump version --------------------------------------------------------

note ""
note "bumping version to $date_str..."
npm pkg set version="$date_str" --silent
npm install

changed="$(git status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')"
changed="${changed% }"

if [ -z "$changed" ]; then
  # package.json was already at $date_str -- e.g. a prior release attempt got
  # this far and no further. Nothing to bump, tag HEAD as-is.
  note "package.json is already at $date_str -- nothing to bump"
elif [ "$changed" = "package-lock.json package.json" ]; then
  git add package.json package-lock.json
  git commit -q -m "$(cat <<EOF
Bump version to $date_str to match release tag

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
  git push origin main
else
  die "unexpected changes after version bump (expected only package.json + package-lock.json): $changed"
fi

# ---- tag -----------------------------------------------------------------

note "tagging $tag..."
git tag "$tag"
git push origin "$tag"

# ---- snapshot to the mirror ----------------------------------------------

note "exporting snapshot to $PUBLIC_REPO..."
pr_url="$("$ROOT/scripts/sync-public.sh" export "$tag")"
[ -n "$pr_url" ] || die "sync-public export produced no pull request url"
note "pull request: $pr_url"

note "merging snapshot pull request..."
pr_number="${pr_url##*/}"
gh pr merge "$pr_number" --repo "$PUBLIC_REPO" --squash --delete-branch

# ---- release on the mirror -----------------------------------------------

note "creating release $tag on $PUBLIC_REPO..."
gh release create "$tag" --repo "$PUBLIC_REPO" \
  --title "$date_str" \
  --target main \
  --notes "$notes"

# ---- wait for the dmg ----------------------------------------------------

note "waiting for release.yml to build the dmg..."
run_id=""
for _ in $(seq 1 15); do
  run_id="$(gh run list --repo "$PUBLIC_REPO" --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [ -n "$run_id" ] && break
  sleep 2
done
[ -n "$run_id" ] || die "no release.yml run appeared for $PUBLIC_REPO -- check https://github.com/$PUBLIC_REPO/actions"

if ! gh run watch "$run_id" --repo "$PUBLIC_REPO" --exit-status; then
  die "release.yml failed -- $tag exists but has no dmg yet. Inspect: gh run view $run_id --repo $PUBLIC_REPO --log-failed
Then retry the same run: gh run rerun $run_id --repo $PUBLIC_REPO"
fi

note "done. assets on $tag:"
gh release view "$tag" --repo "$PUBLIC_REPO" --json assets --jq '.assets[].name' >&2
