#!/usr/bin/env bash
set -euo pipefail

# Generic update script for Daaboulex Nix Packaging Standard
# Reads config from .github/update.json
# Contract: exit 0 = success/no-update, exit 1 = failed, exit 2 = network error

OUTPUT_FILE="${GITHUB_OUTPUT:-/tmp/update-outputs.env}"
: >"$OUTPUT_FILE"

output() { echo "$1=$2" >>"$OUTPUT_FILE"; }

log() { echo "==> $*"; }
warn() { echo "::warning::$*"; }
err() { echo "::error::$*"; }

# --- Read config ---
if [ ! -f .github/update.json ]; then
  log "No .github/update.json — skipping update"
  output "updated" "false"
  exit 0
fi

CONFIG=$(cat .github/update.json)
UPSTREAM_TYPE=$(echo "$CONFIG" | jq -r '.upstream.type')
PACKAGE=$(echo "$CONFIG" | jq -r '.package')
PACKAGE_FILE=$(echo "$CONFIG" | jq -r '.packageFile // "package.nix"')
HASH_FIELDS=$(echo "$CONFIG" | jq -r '.hashes // [] | .[]')

output "package_name" "$PACKAGE"

# --- No-upstream repos skip ---
if [ "$UPSTREAM_TYPE" = "none" ] || [ "$UPSTREAM_TYPE" = "null" ]; then
  log "Upstream type is 'none' — skipping"
  output "updated" "false"
  exit 0
fi

# --- Get current version ---
if [ "$PACKAGE_FILE" = "version.json" ]; then
  CURRENT_VERSION=$(jq -r '.version // .rev' version.json)
else
  CURRENT_VERSION=$(grep -oP 'version\s*=\s*"\K[^"]+' "$PACKAGE_FILE" | head -1)
fi
output "old_version" "$CURRENT_VERSION"
log "Current version: $CURRENT_VERSION"

# --- Fetch latest upstream version ---
fetch_latest() {
  local retries=3 delay=2
  for i in $(seq 1 $retries); do
    if RESULT=$(eval "$1" 2>/dev/null) && [ -n "$RESULT" ]; then
      echo "$RESULT"
      return 0
    fi
    log "Retry $i/$retries (waiting ${delay}s)..."
    sleep $delay
    delay=$((delay * 2))
  done
  return 1
}

case "$UPSTREAM_TYPE" in
github-release)
  OWNER=$(echo "$CONFIG" | jq -r '.upstream.owner')
  REPO=$(echo "$CONFIG" | jq -r '.upstream.repo')
  API_URL="https://api.github.com/repos/$OWNER/$REPO/releases/latest"
  LATEST_TAG=$(fetch_latest "curl -sfL '$API_URL' | jq -r '.tag_name'") || {
    warn "Failed to fetch latest release from $OWNER/$REPO"
    output "updated" "false"
    exit 2
  }
  LATEST_VERSION="${LATEST_TAG#v}"
  output "upstream_url" "https://github.com/$OWNER/$REPO/releases/tag/$LATEST_TAG"
  ;;

github-tag)
  OWNER=$(echo "$CONFIG" | jq -r '.upstream.owner')
  REPO=$(echo "$CONFIG" | jq -r '.upstream.repo')
  LATEST_TAG=$(fetch_latest "curl -sfL 'https://api.github.com/repos/$OWNER/$REPO/tags?per_page=1' | jq -r '.[0].name'") || {
    warn "Failed to fetch tags from $OWNER/$REPO"
    output "updated" "false"
    exit 2
  }
  LATEST_VERSION="${LATEST_TAG#v}"
  output "upstream_url" "https://github.com/$OWNER/$REPO/releases/tag/$LATEST_TAG"
  ;;

github-commit)
  OWNER=$(echo "$CONFIG" | jq -r '.upstream.owner')
  REPO=$(echo "$CONFIG" | jq -r '.upstream.repo')
  BRANCH=$(echo "$CONFIG" | jq -r '.upstream.branch // "main"')
  LATEST_COMMIT=$(fetch_latest "curl -sfL 'https://api.github.com/repos/$OWNER/$REPO/commits/$BRANCH' | jq -r '.sha'") || {
    warn "Failed to fetch commits from $OWNER/$REPO"
    output "updated" "false"
    exit 2
  }
  LATEST_VERSION="${LATEST_COMMIT:0:7}"
  FULL_REV="$LATEST_COMMIT"
  output "upstream_url" "https://github.com/$OWNER/$REPO/commit/$LATEST_COMMIT"
  ;;

gitlab-tag)
  HOST=$(echo "$CONFIG" | jq -r '.upstream.host // "gitlab.com"')
  PROJECT=$(echo "$CONFIG" | jq -r '.upstream.project')
  ENCODED="${PROJECT//\//%2F}"
  LATEST_TAG=$(fetch_latest "curl -sfL 'https://$HOST/api/v4/projects/$ENCODED/repository/tags?per_page=1' | jq -r '.[0].name'") || {
    warn "Failed to fetch tags from $PROJECT"
    output "updated" "false"
    exit 2
  }
  LATEST_VERSION="${LATEST_TAG#v}"
  output "upstream_url" "https://$HOST/$PROJECT/-/releases/$LATEST_TAG"
  ;;

gitea-commit)
  HOST=$(echo "$CONFIG" | jq -r '.upstream.host')
  OWNER=$(echo "$CONFIG" | jq -r '.upstream.owner')
  REPO=$(echo "$CONFIG" | jq -r '.upstream.repo')
  BRANCH=$(echo "$CONFIG" | jq -r '.upstream.branch // "main"')
  LATEST_COMMIT=$(fetch_latest "curl -sfL 'https://$HOST/api/v1/repos/$OWNER/$REPO/branches/$BRANCH' | jq -r '.commit.id'") || {
    warn "Failed to fetch from Gitea $HOST/$OWNER/$REPO"
    output "updated" "false"
    exit 2
  }
  LATEST_VERSION="${LATEST_COMMIT:0:7}"
  FULL_REV="$LATEST_COMMIT"
  output "upstream_url" "https://$HOST/$OWNER/$REPO/commit/$LATEST_COMMIT"
  ;;

gitlab-commit)
  HOST=$(echo "$CONFIG" | jq -r '.upstream.host // "gitlab.com"')
  PROJECT=$(echo "$CONFIG" | jq -r '.upstream.project')
  ENCODED="${PROJECT//\//%2F}"
  BRANCH=$(echo "$CONFIG" | jq -r '.upstream.branch // "main"')
  LATEST_COMMIT=$(fetch_latest "curl -sfL 'https://$HOST/api/v4/projects/$ENCODED/repository/branches/$BRANCH' | jq -r '.commit.id'") || {
    warn "Failed to fetch from GitLab $PROJECT"
    output "updated" "false"
    exit 2
  }
  LATEST_VERSION="${LATEST_COMMIT:0:7}"
  FULL_REV="$LATEST_COMMIT"
  output "upstream_url" "https://$HOST/$PROJECT/-/commit/$LATEST_COMMIT"
  ;;

git-ls-remote)
  URL=$(echo "$CONFIG" | jq -r '.upstream.url')
  BRANCH=$(echo "$CONFIG" | jq -r '.upstream.branch // "main"')
  LATEST_COMMIT=$(fetch_latest "git ls-remote '$URL' 'refs/heads/$BRANCH' | cut -f1") || {
    warn "Failed to ls-remote $URL"
    output "updated" "false"
    exit 2
  }
  LATEST_VERSION="${LATEST_COMMIT:0:7}"
  FULL_REV="$LATEST_COMMIT"
  output "upstream_url" "$URL"
  ;;

custom)
  # OCCT-specific: download binaries, extract version from .NET metadata, compute hashes.
  # Handles both Stable and Testing branches independently.
  ANY_UPDATED="false"
  STABLE_VERSION="" TESTING_VERSION=""

  for BRANCH in Stable Testing; do
    BRANCH_URL="https://www.ocbase.com/download-bin/edition:Personal/os:Linux/branch:$BRANCH"
    TMPBIN="/tmp/occt-$BRANCH"

    log "Downloading OCCT $BRANCH binary..."
    HTTP_CODE=$(curl -sL -w '%{http_code}' -o "$TMPBIN" "$BRANCH_URL" 2>/dev/null) || {
      warn "Failed to download $BRANCH binary"
      output "updated" "false"
      exit 2
    }

    if [ "$HTTP_CODE" -ne 200 ]; then
      warn "$BRANCH download returned HTTP $HTTP_CODE"
      output "updated" "false"
      exit 2
    fi

    # Validate: must be >100MB ELF binary
    FILE_SIZE=$(stat -c%s "$TMPBIN")
    if [ "$FILE_SIZE" -lt 104857600 ]; then
      warn "$BRANCH binary too small (${FILE_SIZE} bytes) — likely an error page"
      output "updated" "false"
      exit 2
    fi
    file "$TMPBIN" | grep -q ELF || {
      warn "$BRANCH download is not an ELF binary"
      output "updated" "false"
      exit 2
    }

    # Extract version from .NET assembly metadata
    NEW_VERSION=$(strings "$TMPBIN" | grep -oP 'assemblyIdentity version="\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$NEW_VERSION" ]; then
      NEW_VERSION=$(strings "$TMPBIN" | grep -oP '^\t\K[0-9]+\.[0-9]+\.[0-9]+(?=\.[0-9]+$)' | head -1)
    fi
    if [ -z "$NEW_VERSION" ]; then
      warn "Could not extract version from $BRANCH binary"
      output "updated" "false"
      exit 2
    fi

    # Compute SRI hash
    NEW_HASH=$(nix hash file --sri "$TMPBIN")

    log "$BRANCH: version=$NEW_VERSION hash=$NEW_HASH"

    if [ "$BRANCH" = "Stable" ]; then
      STABLE_VERSION="$NEW_VERSION"
    else
      TESTING_VERSION="$NEW_VERSION"
    fi

    # Get current values from package.nix
    BLOCK_START=$(grep -n "${BRANCH} = {" "$PACKAGE_FILE" | head -1 | cut -d: -f1)
    if [ -z "$BLOCK_START" ]; then
      warn "Could not find $BRANCH block in $PACKAGE_FILE"
      continue
    fi

    CUR_VER=$(tail -n +"$BLOCK_START" "$PACKAGE_FILE" | grep -oP 'version\s*=\s*"\K[^"]+' | head -1)
    CUR_HASH=$(tail -n +"$BLOCK_START" "$PACKAGE_FILE" | grep -oP 'hash\s*=\s*"\K[^"]+' | head -1)

    if [ "$CUR_VER" = "$NEW_VERSION" ] && [ "sha256-$CUR_HASH" = "$NEW_HASH" ] 2>/dev/null; then
      log "$BRANCH already up to date ($NEW_VERSION)"
      continue
    fi

    log "Updating $BRANCH: $CUR_VER → $NEW_VERSION"
    ANY_UPDATED="true"

    # Update version line
    VER_OFFSET=$(tail -n +"$BLOCK_START" "$PACKAGE_FILE" | grep -n 'version =' | head -1 | cut -d: -f1)
    VER_LINE=$((BLOCK_START + VER_OFFSET - 1))
    sed -i "${VER_LINE}s|version = \".*\"|version = \"${NEW_VERSION}\"|" "$PACKAGE_FILE"

    # Update hash line
    HASH_OFFSET=$(tail -n +"$BLOCK_START" "$PACKAGE_FILE" | grep -n 'hash =' | head -1 | cut -d: -f1)
    HASH_LINE=$((BLOCK_START + HASH_OFFSET - 1))
    sed -i "${HASH_LINE}s|hash = \".*\"|hash = \"${NEW_HASH}\"|" "$PACKAGE_FILE"

    rm -f "$TMPBIN"
  done

  # Report using Stable version as the primary
  output "new_version" "${STABLE_VERSION:-unknown}"
  output "upstream_url" "https://www.ocbase.com"

  if [ "$ANY_UPDATED" = "false" ]; then
    log "Both branches already up to date"
    output "updated" "false"
    exit 0
  fi

  output "updated" "true"

  # Run verification chain inline (skip generic hash extraction)
  log "Running verification chain..."

  log "Step 1/3: nix flake check --no-build"
  if ! nix flake check --no-build 2>&1; then
    err "Eval check failed after OCCT update"
    output "error_type" "eval-error"
    exit 1
  fi

  log "Step 2/3: nix build (Stable)"
  if ! nix build .#default --no-link --print-build-logs 2>&1; then
    err "Stable build failed"
    output "error_type" "build-error"
    exit 1
  fi

  log "Step 3/3: nix build (Testing)"
  if ! nix build .#occt-testing --no-link --print-build-logs 2>&1; then
    err "Testing build failed"
    output "error_type" "build-error"
    exit 1
  fi

  log "OCCT update verified: ${STABLE_VERSION} (Stable), ${TESTING_VERSION} (Testing)"
  exit 0
  ;;

*)
  err "Unknown upstream type: $UPSTREAM_TYPE"
  output "updated" "false"
  exit 2
  ;;
esac

log "Latest version: $LATEST_VERSION"
output "new_version" "$LATEST_VERSION"

# --- Compare versions ---
if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
  log "Already up to date"
  output "updated" "false"
  exit 0
fi

log "Update found: $CURRENT_VERSION → $LATEST_VERSION"
output "updated" "true"

# --- Update version in package file ---
if [ "$PACKAGE_FILE" = "version.json" ]; then
  jq --arg v "$LATEST_VERSION" --arg r "${FULL_REV:-$LATEST_VERSION}" \
    '.version = $v | .rev = $r | .date = (now | strftime("%Y-%m-%d"))' \
    version.json >version.json.tmp && mv version.json.tmp version.json
else
  sed -i "s|version = \"$CURRENT_VERSION\"|version = \"$LATEST_VERSION\"|" "$PACKAGE_FILE"
  # Update rev for commit-tracking repos
  if [ -n "${FULL_REV:-}" ]; then
    CURRENT_REV=$(grep -oP 'rev\s*=\s*"\K[^"]+' "$PACKAGE_FILE" | head -1)
    if [ -n "$CURRENT_REV" ]; then
      sed -i "s|rev = \"$CURRENT_REV\"|rev = \"$FULL_REV\"|" "$PACKAGE_FILE"
    fi
  fi
fi

# --- Extract hashes (iterative build-fail-parse) ---
# IMPORTANT: hashes in update.json MUST be ordered by evaluation dependency:
# source hash first (fetcher fails before build), then vendor hashes (cargoHash, npmDepsHash, vendorHash).
# Each iteration sets one hash to dummy, builds to extract the correct value, then restores it.
# If nix outputs multiple "got: sha256-..." lines, head -1 takes the first (the fetcher hash).
DUMMY_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

for FIELD in $HASH_FIELDS; do
  log "Extracting hash for: $FIELD"

  # Get current hash pattern
  CURRENT_HASH=$(grep -oP "${FIELD}\s*=\s*\"sha256-\K[^\"]*" "$PACKAGE_FILE" | head -1)
  if [ -z "$CURRENT_HASH" ]; then
    warn "Could not find $FIELD in $PACKAGE_FILE — skipping"
    continue
  fi

  # Set to dummy hash
  sed -i "s|${FIELD} = \"sha256-${CURRENT_HASH}\"|${FIELD} = \"${DUMMY_HASH}\"|" "$PACKAGE_FILE"

  # Build and extract correct hash
  log "Building to extract $FIELD hash..."
  BUILD_OUTPUT=$(nix build .#default 2>&1 || true)
  NEW_HASH=$(echo "$BUILD_OUTPUT" | grep -oP 'got:\s+sha256-\K\S+' | head -1)

  if [ -z "$NEW_HASH" ]; then
    err "Failed to extract $FIELD hash"
    output "error_type" "hash-extraction"
    output "error_log" "/tmp/update.log"
    exit 1
  fi

  log "Extracted $FIELD: sha256-$NEW_HASH"
  sed -i "s|${FIELD} = \"${DUMMY_HASH}\"|${FIELD} = \"sha256-${NEW_HASH}\"|" "$PACKAGE_FILE"
done

# --- Verification chain ---
log "Running verification chain..."

# 1. Eval check
log "Step 1/4: nix flake check --no-build"
if ! nix flake check --no-build 2>&1; then
  err "Eval check failed"
  output "error_type" "eval-error"
  exit 1
fi

# 2. Clean build
log "Step 2/4: nix build (clean)"
if ! nix build .#default --no-link --print-build-logs 2>&1; then
  err "Build failed"
  output "error_type" "build-error"
  exit 1
fi

# 3. Binary verification
VERIFY_BINARY=$(echo "$CONFIG" | jq -r '.verify.binary // empty')
VERIFY_ARGS=$(echo "$CONFIG" | jq -r '.verify.args // "--version"')
VERIFY_CHECK=$(echo "$CONFIG" | jq -r '.verify.check // empty')

if [ -n "$VERIFY_BINARY" ]; then
  log "Step 3/4: Binary verification (./result/bin/$VERIFY_BINARY $VERIFY_ARGS)"
  nix build .#default # need result symlink
  if ! ./result/bin/"$VERIFY_BINARY" "$VERIFY_ARGS" 2>&1; then
    err "Binary verification failed"
    output "error_type" "verification-error"
    exit 1
  fi
elif [ "$VERIFY_CHECK" = "elf" ]; then
  log "Step 3/4: ELF verification"
  nix build .#default
  FOUND=$(find result/bin/ -type f -executable 2>/dev/null | head -1)
  if [ -z "$FOUND" ]; then
    FOUND=$(find result/lib/ -name "*.so" 2>/dev/null | head -1)
  fi
  if [ -n "$FOUND" ]; then
    file "$FOUND" | grep -q ELF || {
      err "Not an ELF binary: $FOUND"
      output "error_type" "verification-error"
      exit 1
    }
  fi
elif [ "$VERIFY_CHECK" = "eval" ]; then
  log "Step 3/4: Eval verification (already passed in step 1)"
elif [ "$VERIFY_CHECK" = "desktop" ]; then
  log "Step 3/4: Desktop file verification"
  nix build .#default
  find result/share/applications/ -name "*.desktop" 2>/dev/null | head -1 | grep -q . || warn "No desktop file found"
else
  log "Step 3/4: No binary verification configured — skipping"
fi

# 4. Runtime dependency check (ldd)
if [ -n "$VERIFY_BINARY" ]; then
  log "Step 4/4: ldd check"
  if file ./result/bin/"$VERIFY_BINARY" 2>/dev/null | grep -q ELF; then
    MISSING=$(ldd ./result/bin/"$VERIFY_BINARY" 2>&1 | grep "not found" || true)
    if [ -n "$MISSING" ]; then
      err "Missing shared libraries:"
      echo "$MISSING"
      output "error_type" "missing-deps"
      exit 1
    fi
  fi
else
  log "Step 4/4: ldd check — skipping (no binary configured)"
fi

# Clean up build artifact
rm -f result

log "Update verified: $CURRENT_VERSION → $LATEST_VERSION"
exit 0
