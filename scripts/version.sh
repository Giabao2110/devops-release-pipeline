#!/usr/bin/env bash
# Prints build metadata as KEY=VALUE lines (append to $GITHUB_OUTPUT in CI).
#
#   on a tag v1.4.0            -> VERSION=1.4.0
#   3 commits after v1.4.0     -> VERSION=1.4.0-dev.3+abc1234
#   no tag yet                 -> VERSION=0.0.0-dev.<commit count>+abc1234
#
# The commit SHA is always available separately, so every artifact can be
# traced back to the exact source revision.
set -euo pipefail

commit="$(git rev-parse --short=7 HEAD)"
build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if desc="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --long 2>/dev/null)"; then
  # desc looks like v1.4.0-3-gabc1234
  tag="${desc%-*-g*}"
  ahead="${desc#"$tag"-}"; ahead="${ahead%%-g*}"
  base="${tag#v}"
  if [[ "$ahead" == "0" ]]; then
    version="$base"
  else
    version="${base}-dev.${ahead}+${commit}"
  fi
else
  version="0.0.0-dev.$(git rev-list --count HEAD)+${commit}"
fi

# Docker tags cannot contain '+', so expose a tag-safe variant too.
image_tag="${version//+/-}"

echo "VERSION=${version}"
echo "IMAGE_TAG=${image_tag}"
echo "COMMIT=${commit}"
echo "BUILD_DATE=${build_date}"
