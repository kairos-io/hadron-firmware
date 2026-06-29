#!/usr/bin/env bash

## Aggregate the release.json asset from every GitHub release into a single
## data.json file consumed by the static page (site/index.html).
##
## The release.json attached to each firmware release has the shape:
##   { "images": [ {"<name>": "<image ref>"}, ... ],
##     "sysext": [ {"<file>": "<download url>"}, ... ] }
##
## This script flattens those arrays of single key objects into plain objects
## (name -> value) and collects one entry per release, newest tag first.
##
## Environment:
##   REPO     owner/repo to read releases from (required)
##   GH_TOKEN token used by the gh CLI (required for private repos / rate limits)
## Usage:
##   REPO=owner/repo ./site/build-data.sh [output_file]

set -euo pipefail

REPO="${REPO:?REPO is required (owner/repo)}"
OUT="${1:-data.json}"

echo "Collecting releases for ${REPO}..." >&2

## Pull every release with the metadata we care about. --paginate walks all pages.
releases=$(gh api --paginate "repos/${REPO}/releases" \
  -q '.[] | {tag: .tag_name, html_url: .html_url, published_at: .published_at, prerelease: .prerelease, assets: [.assets[] | {name: .name, id: .id}]}' \
  | jq -s '.')

combined='[]'
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  tag=$(jq -r '.tag' <<<"$rel")
  html_url=$(jq -r '.html_url' <<<"$rel")
  published_at=$(jq -r '.published_at // ""' <<<"$rel")
  prerelease=$(jq -r '.prerelease // false' <<<"$rel")

  asset_id=$(jq -r 'first(.assets[] | select(.name=="release.json") | .id) // empty' <<<"$rel")
  if [[ -z "$asset_id" ]]; then
    echo "  - ${tag}: no release.json asset, skipping" >&2
    continue
  fi

  ## Fetch the raw release.json asset bytes (the assets endpoint redirects to the
  ## download URL when asked for octet-stream; gh follows the redirect).
  if ! rj=$(gh api -H "Accept: application/octet-stream" "repos/${REPO}/releases/assets/${asset_id}" 2>/dev/null); then
    echo "  - ${tag}: failed to download release.json, skipping" >&2
    continue
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$rj"; then
    echo "  - ${tag}: release.json is not valid JSON, skipping" >&2
    continue
  fi

  entry=$(jq -n \
    --arg tag "$tag" \
    --arg url "$html_url" \
    --arg published "$published_at" \
    --argjson prerelease "$prerelease" \
    --argjson rj "$rj" \
    '{
      tag: $tag,
      html_url: $url,
      published_at: $published,
      prerelease: $prerelease,
      images: (($rj.images // []) | add // {}),
      sysext: (($rj.sysext // []) | add // {})
    }')
  combined=$(jq --argjson e "$entry" '. += [$e]' <<<"$combined")
  echo "  - ${tag}: added" >&2
done < <(jq -c '.[]' <<<"$releases")

## Sort releases by published date (newest first), falling back to tag order.
jq -n --argjson r "$combined" --arg repo "$REPO" \
  '{
    generated: (now | todate),
    repo: $repo,
    releases: ($r | sort_by(.published_at) | reverse)
  }' > "$OUT"

count=$(jq '.releases | length' "$OUT")
echo "Wrote ${count} release(s) to ${OUT}" >&2
