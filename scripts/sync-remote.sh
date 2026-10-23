#!/usr/bin/env bash
# Build or refresh an OSTree repository from the stable Flatpak bundles
# published on GitHub Releases, then write a .flatpakrepo file and a small
# landing page.
#
# Usage: scripts/sync-remote.sh [SITE_DIR]
#
# Environment:
#   FLATPAK_GPG_PRIVATE_KEY  armored private key (required)
#   FLATPAK_GPG_KEY_ID       key ID or fingerprint (derived if unset)
#   PAGES_URL                public base URL; derived on GitHub Actions
#   UPSTREAM_REPO            default Viren070/AIOStreams
#   APP_ID                   default io.github.viren070.aiostreams
#   ARCHES                   default "x86_64 aarch64"
#   STABLE_BRANCH            default master (matches the upstream bundles)
#   PRUNE_DEPTH              versions kept, default 10
#   FORCE_SYNC               1 to rebuild even if upstream has not changed

set -euo pipefail

site=${1:-site}
app_id=${APP_ID:-io.github.viren070.aiostreams}
upstream=${UPSTREAM_REPO:-Viren070/AIOStreams}
arches=${ARCHES:-"x86_64 aarch64"}
stable_branch=${STABLE_BRANCH:-master}
prune_depth=${PRUNE_DEPTH:-10}
force=${FORCE_SYNC:-0}

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for command in flatpak ostree gpg curl; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

[[ -n ${FLATPAK_GPG_PRIVATE_KEY:-} ]] ||
  die "FLATPAK_GPG_PRIVATE_KEY is not set"
[[ -n ${PAGES_URL:-} || -n ${GITHUB_REPOSITORY:-} ]] ||
  die "set PAGES_URL to the public base URL of the site"

if [[ -z ${PAGES_URL:-} ]]; then
  owner=${GITHUB_REPOSITORY%%/*}
  repo=${GITHUB_REPOSITORY#*/}
  owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
  repo=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
  if [[ $repo == "$owner.github.io" ]]; then
    PAGES_URL="https://$owner.github.io/"
  else
    PAGES_URL="https://$owner.github.io/$repo/"
  fi
fi
[[ $PAGES_URL == */ ]] || PAGES_URL="$PAGES_URL/"

mkdir -p "$site"
site=$(cd "$site" && pwd)
repo_dir="$site/repo"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say "Importing signing key"
export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
printf '%s\n' "$FLATPAK_GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1 ||
  die "could not import FLATPAK_GPG_PRIVATE_KEY"

key_id=${FLATPAK_GPG_KEY_ID:-}
if [[ -z $key_id ]]; then
  key_id=$(gpg --batch --with-colons --list-secret-keys |
    awk -F: '/^sec:/ { print $5; exit }')
fi
[[ -n $key_id ]] || die "no secret key found after importing the private key"
key_fpr=$(gpg --batch --with-colons --list-secret-keys "$key_id" |
  awk -F: '/^fpr:/ { print $10; exit }')
[[ -n $key_fpr ]] || die "could not read the fingerprint of key $key_id"

# Release assets use the marketing names x64/arm64.
asset_name() {
  local arch=$1
  case $arch in
    x86_64) arch=x64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture: $arch" ;;
  esac
  printf 'aiostreams-desktop-linux-%s.flatpak' "$arch"
}

asset_url() {
  printf 'https://github.com/%s/releases/download/desktop/%s' \
    "$upstream" "$(asset_name "$1")"
}

# HEAD the release asset and describe it. GitHub redirects to a signed object
# URL; the final ETag and length change whenever the asset is replaced, which is
# all the state we need to decide whether to rebuild.
probe_asset() {
  local arch=$1
  local url headers etag size last_modified
  url=$(asset_url "$arch")

  if ! headers=$(curl -fsSIL --retry 3 --retry-delay 2 "$url" 2>/dev/null | tr -d '\r'); then
    die "could not find $url"
  fi

  etag=$(printf '%s\n' "$headers" |
    awk 'tolower($1) == "etag:" { v=$2 } END { print v }')
  size=$(printf '%s\n' "$headers" |
    awk 'tolower($1) == "content-length:" { v=$2 } END { print v }')
  last_modified=$(printf '%s\n' "$headers" |
    awk 'tolower($1) == "last-modified:" { sub(/^[^:]*:[ \t]*/, ""); v=$0 } END { print v }')
  printf '%s|%s|%s' "${etag:-?}" "${size:-?}" "${last_modified:-?}"
}

# Build the state we would publish before doing any work. Without this, every
# scheduled run would re-sign the summary (its timestamp changes) and create a
# new commit even when upstream has not released anything.
state_lines=()
for arch in $arches; do
  state_lines+=("stable $arch $(probe_asset "$arch")")
done

new_state="$work/state"
{
  printf 'version=1\n'
  printf 'key=%s\n' "$key_fpr"
  printf '%s\n' "${state_lines[@]}"
} >"$new_state"

write_site_files() {
  local key_b64
  gpg --batch --export "$key_id" >"$work/key.gpg"
  key_b64=$(base64 <"$work/key.gpg" | tr -d '\n')

  cat >"$site/aiostreams.flatpakrepo" <<EOF
[Flatpak Repo]
Title=AIOStreams Desktop (unofficial)
Url=${PAGES_URL}repo/
Homepage=https://github.com/${upstream}
Comment=Unofficial Flatpak remote for the AIOStreams desktop app
Description=Automatic updates for the AIOStreams desktop app, mirrored from its GitHub Releases.
GPGKey=${key_b64}
EOF
  cp "$work/key.gpg" "$site/aiostreams.gpg"
  sed "s|@URL@|${PAGES_URL}|g" "$(dirname "$0")/../templates/index.html" >"$site/index.html"
  cp "$new_state" "$site/.upstream-state"
  touch "$site/.nojekyll"
}

if [[ $force != 1 && -f $site/.upstream-state ]] &&
  cmp -s "$new_state" "$site/.upstream-state" &&
  [[ -f $repo_dir/config && -f $site/aiostreams.flatpakrepo && -f $site/index.html ]]; then
  say "Up to date"
  write_site_files
  exit 0
fi

# A new signing key cannot validate commits signed by the old one, so start the
# repository again.
old_key=$(sed -n 's/^key=//p' "$site/.upstream-state" 2>/dev/null || true)
if [[ -n $old_key && $old_key != "$key_fpr" ]]; then
  say "Signing key changed; rebuilding repository"
  rm -rf "$repo_dir"
fi

if [[ ! -f $repo_dir/config ]]; then
  say "Creating repository"
  mkdir -p "$repo_dir"
  ostree init --repo="$repo_dir" --mode=archive
fi

import_release() {
  local arch asset url file ref

  for arch in $arches; do
    asset=$(asset_name "$arch")
    url=$(asset_url "$arch")
    file="$work/stable-$arch.flatpak"

    say "Downloading $asset"
    curl -fsSL --retry 3 --retry-delay 2 --location "$url" -o "$file" ||
      die "could not download $url"
    [[ $(head -c 7 "$file") == flatpak ]] ||
      die "$url is not a Flatpak bundle"

    ref="app/$app_id/$arch/$stable_branch"
    say "Importing $ref"
    flatpak build-import-bundle \
      --no-update-summary \
      --gpg-sign="$key_id" \
      --gpg-homedir="$GNUPGHOME" \
      --ref="$ref" \
      "$repo_dir" "$file"
    rm -f "$file"
  done
}

# `build-import-bundle --ref` changes the ref but leaves the commit's own
# ref-binding metadata alone. Normally the upstream bundle already says master;
# this also repairs the branch if upstream changes it.
ensure_binding() {
  local ref=$1 binding
  ostree --repo="$repo_dir" show "$ref" >/dev/null 2>&1 || return 0
  binding=$(ostree --repo="$repo_dir" show --print-metadata-key=xa.ref "$ref" 2>/dev/null |
    tr -d "'" || true)
  [[ $binding == "$ref" ]] && return 0

  say "Rebinding $ref"
  flatpak build-commit-from \
    --src-ref="$ref" \
    --force \
    --gpg-sign="$key_id" \
    --gpg-homedir="$GNUPGHOME" \
    --no-update-summary \
    "$repo_dir" "$ref"
}

# If this repository used to mirror nightlies, drop those branches so the
# published remote contains stable only.
remove_nightly_refs() {
  local ref
  while IFS= read -r ref; do
    [[ $ref == app/$app_id/*/nightly ]] || continue
    say "Removing old branch $ref"
    ostree --repo="$repo_dir" refs --delete "$ref"
  done < <(ostree --repo="$repo_dir" refs)
}

say "Syncing stable release"
import_release
for arch in $arches; do
  ensure_binding "app/$app_id/$arch/$stable_branch"
done
remove_nightly_refs

say "Signing repository metadata"
update_args=(
  --title="AIOStreams Desktop (unofficial)"
  --comment="Unofficial Flatpak remote for the AIOStreams desktop app"
  --description="Automatic updates for the AIOStreams desktop app, mirrored from its GitHub Releases."
  --homepage="https://github.com/$upstream"
  --default-branch="$stable_branch"
  --gpg-sign="$key_id"
  --gpg-homedir="$GNUPGHOME"
  --generate-static-deltas
)
if [[ $prune_depth -gt 0 ]]; then
  update_args+=(--prune --prune-depth="$prune_depth")
fi
flatpak build-update-repo "${update_args[@]}" "$repo_dir"
rm -f "$repo_dir/.lock"

say "Writing remote files"
write_site_files

flatpak repo "$repo_dir" >/dev/null
say "Repository ready at ${PAGES_URL}repo/"
