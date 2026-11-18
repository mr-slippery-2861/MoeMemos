#!/usr/bin/env bash
set -euo pipefail

export_dir=""
if [[ "${1:-}" == --export-only && -n "${2:-}" ]]; then
  export_dir="$2"
  shift 2
fi
if [[ $# -gt 1 || ($# == 1 && ! "$1" =~ ^[1-9][0-9]{0,3}$) ]]; then
  printf 'Usage: %s [--export-only DIRECTORY] [BUILD_NUMBER]\n' "$0" >&2
  exit 2
fi
build="${1:-}"
if [[ -n "$export_dir" ]]; then
  mkdir -p "$export_dir"
  export_dir="$(cd "$export_dir" && pwd)"
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo="$PWD"
team="${MOEMEMOS_IOS_TEAM_ID:-H53J58LAD7}"
prefix="${MOEMEMOS_ADHOC_BUNDLE_ID:-tech.ummon.moememos}"
signing_dir="${MOEMEMOS_ADHOC_SIGNING_DIR:-$HOME/Library/Application Support/Jarvis-iOS/signing}"
device_file="${MOEMEMOS_ADHOC_DEVICE_FILE:-$repo/adhoc-devices.txt}"
release_repo="neilc6321/jarvis-ios"
keychain="$signing_dir/release.keychain-db"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { printf 'Invalid signing team.\n' >&2; exit 2; }

if [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  if GH_TOKEN="$(gh auth token --hostname github.com --user neilc6321 2>/dev/null)"; then export GH_TOKEN; fi
fi
require_private_repo() {
  [[ "$(gh api "repos/$release_repo" --jq .visibility)" == private ]] || {
    printf 'Cannot verify that %s is private.\n' "$release_repo" >&2; return 1;
  }
}
if [[ -z "$export_dir" || -z "$build" ]]; then require_private_repo; fi
if [[ -z "$build" ]]; then
  build="$(gh api --paginate "repos/$release_repo/git/matching-refs/tags/moememos-v" --jq '.[].ref' | python3 -c '
import re, sys
builds = [int(m[1]) for line in sys.stdin if (m := re.fullmatch(r"refs/tags/moememos-v\d+(?:\.\d+){0,2}-adhoc\.([1-9]\d{0,3})\n?", line))]
print(max(builds, default=0) + 1)
')"
fi
[[ "$build" =~ ^[1-9][0-9]{0,3}$ ]] || { printf 'Build number must be 1–9999.\n' >&2; exit 2; }
umask 077
stage="$(mktemp -d "${TMPDIR:-/tmp}/moememos-adhoc.XXXXXX")"
trap 'result=$?; if (( result != 0 )); then printf "Release failed; logs and artifacts: %s\n" "$stage" >&2; else rm -rf "$stage"; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for file in release.keychain-db keychain-password certificate-id distribution.cer; do
  [[ -s "$signing_dir/$file" ]] || { printf 'Missing signing file: %s\n' "$signing_dir/$file" >&2; exit 1; }
done
unlock_keychain() { security unlock-keychain -p "$(cat "$signing_dir/keychain-password")" "$keychain"; }
unlock_keychain
certificate="$(shasum -a 1 "$signing_dir/distribution.cer" | awk '{print toupper($1)}')"
security find-identity -v -p codesigning "$keychain" | grep -Fq "$certificate" || { printf 'Distribution private key unavailable.\n' >&2; exit 1; }
security find-identity -v -p codesigning | grep -Fq "$certificate" || { printf 'Add the release keychain to the user keychain search list.\n' >&2; exit 1; }

printf 'Preparing profiles and source for Moe Memos build %s.\n' "$build" >&2
/usr/bin/ruby "$repo/tools/adhoc-signing.rb" --profiles "$(cat "$signing_dir/certificate-id")" "$stage" "$device_file" "$prefix"
commit="$(git rev-parse HEAD)"
source_state="$commit"
if [[ -n "$(git status --porcelain)" ]]; then source_state="$commit (working tree snapshot)"; fi
python3 - "$repo" "$stage/source" <<'PY'
from pathlib import Path
import shutil, subprocess, sys
repo, target = map(Path, sys.argv[1:])
files = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=repo).split(b"\0")
for filename in set(filter(None, files)):
    path = Path(filename.decode())
    source = repo / path
    if not source.exists():
        continue
    destination = target / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination, follow_symlinks=False)
PY
python3 tools/adhoc-package.py prepare "$stage" "$team" "$prefix" "$signing_dir/distribution.cer" "$build"

run_xcodebuild() {
  local phase="$1"; shift
  unlock_keychain
  if xcodebuild "$@" >"$stage/$phase.log" 2>&1; then return 0; fi
  printf 'Xcode %s failed. See %s/%s.log\n' "$phase" "$stage" "$phase" >&2
  awk '/error:|errSecInternalComponent|^Error Domain=|^Command .* failed/ {print}' "$stage/$phase.log" | tail -15 >&2
  return 1
}
printf 'Archiving %s as build %s.\n' "$source_state" "$build" >&2
run_xcodebuild archive -project "$stage/source/MoeMemos.xcodeproj" -scheme MoeMemos -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$stage/MoeMemos.xcarchive" -derivedDataPath "$stage/DerivedData" \
  -skipPackagePluginValidation "DEVELOPMENT_TEAM=$team" "CURRENT_PROJECT_VERSION=$build" \
  CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$certificate" archive
run_xcodebuild export -exportArchive -archivePath "$stage/MoeMemos.xcarchive" \
  -exportOptionsPlist "$stage/ExportOptions.plist" -exportPath "$stage/export"
ditto -x -k "$stage/export/MoeMemos.ipa" "$stage/verify"
version="$(python3 tools/adhoc-package.py verify "$stage" "$team" "$prefix" "$signing_dir/distribution.cer" "$build")"
asset="MoeMemos-$version-build$build-AdHoc.ipa"
mv "$stage/export/MoeMemos.ipa" "$stage/$asset"
digest="$(shasum -a 256 "$stage/$asset" | awk '{print $1}')"
printf '%s  %s\n' "$digest" "$asset" >"$stage/$asset.sha256"
if [[ -n "$export_dir" ]]; then
  cp "$stage/$asset" "$stage/$asset.sha256" "$export_dir/"
  printf 'Verified Ad Hoc export: %s/%s\n' "$export_dir" "$asset"
  exit
fi

require_private_repo
tag="moememos-v$version-adhoc.$build"
target="$(gh api "repos/$release_repo/git/ref/heads/main" --jq .object.sha)"
# Reserve the tag atomically so two publishers cannot replace each other's IPA.
gh api "repos/$release_repo/git/refs" -f "ref=refs/tags/$tag" -f "sha=$target" >/dev/null
cat >"$stage/notes.md" <<EOF
Moe Memos $version, Ad Hoc build $build.

Source: $source_state
Bundle: $prefix
Install: https://adhoc.ummon.tech/?app=moememos
SHA-256: $digest

Signed for the locally configured registered devices. Includes the share extension and widgets.
EOF
gh release create "$tag" "$stage/$asset" "$stage/$asset.sha256" --repo "$release_repo" \
  --verify-tag --draft --title "Moe Memos $version · Ad Hoc $build" --notes-file "$stage/notes.md" >/dev/null
release_id="$(gh release view "$tag" --repo "$release_repo" --json databaseId --jq .databaseId)"
remote_digest="$(gh api "repos/$release_repo/releases/$release_id" --jq ".assets[] | select(.name == \"$asset\") | .digest")"
[[ "$remote_digest" == "sha256:$digest" ]] || { printf 'Uploaded IPA digest does not match; release left as draft.\n' >&2; exit 1; }
gh release edit "$tag" --repo "$release_repo" --draft=false --latest=false >/dev/null
printf 'Published %s\nInstall: https://adhoc.ummon.tech/?app=moememos\n' "$tag"
