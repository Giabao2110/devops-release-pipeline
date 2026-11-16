#!/usr/bin/env bash
# Cross-compile one target and package it with a checksum.
# Usage: scripts/package.sh <goos> <goarch>   (reads VERSION/COMMIT/BUILD_DATE from env or version.sh)
# Output: dist/release-demo_<version>_<goos>_<goarch>.{tar.gz|zip} and a matching .sha256 file.
set -euo pipefail
goos="${1:?goos}"; goarch="${2:?goarch}"
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${VERSION:-}" ]]; then eval "$("$root/scripts/version.sh")"; fi

name="release-demo_${VERSION//+/-}_${goos}_${goarch}"
work="$root/dist/$name"
rm -rf "$work"; mkdir -p "$work"
ext=""; [[ "$goos" == "windows" ]] && ext=".exe"

start=$(date +%s)
( cd "$root/app" && CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build -trimpath \
    -ldflags "-s -w -X main.version=${VERSION} -X main.commit=${COMMIT} -X main.buildDate=${BUILD_DATE}" \
    -o "$work/release-demo${ext}" . )
cp "$root/README.md" "$work/" 2>/dev/null || true
printf '{"version":"%s","commit":"%s","build_date":"%s","os":"%s","arch":"%s"}\n' \
  "$VERSION" "$COMMIT" "$BUILD_DATE" "$goos" "$goarch" > "$work/BUILD_INFO.json"

cd "$root/dist"
if [[ "$goos" == "windows" ]]; then
  archive="$name.zip"
  if command -v zip >/dev/null; then (cd "$name" && zip -qr "../$archive" .)
  else
    # Fallback for machines without zip (e.g. Git Bash on Windows).
    py=python3; python3 -c '' >/dev/null 2>&1 || py=python
    "$py" -c 'import shutil,sys; shutil.make_archive(sys.argv[1], "zip", sys.argv[1])' "$name"
  fi
else
  archive="$name.tar.gz"
  tar -czf "$archive" -C "$name" .
fi
rm -rf "$name"
sha256sum "$archive" > "$archive.sha256"
size=$(wc -c < "$archive" | tr -d ' ')
echo "packaged $archive (${size} bytes) in $(( $(date +%s) - start ))s"
cat "$archive.sha256"
