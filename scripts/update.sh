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
  # The first `version =` literal in package.nix is the compat shim's;
  # the package version lives in the per-branch `sources` blocks.
  CURRENT_VERSION=$(grep -A3 'Stable = {' "$PACKAGE_FILE" | grep -oP 'version\s*=\s*"\K[^"]+' | head -1 || true)
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
  # OCCT (ocbase.com): the binaries carry no readable version metadata (v17+)
  # and both branch URLs re-serve files in place. The download page's
  # __NEXT_DATA__ JSON is the source of truth: versionStr + SHA-256 checksum
  # per edition/OS/branch. When no Testing release exists (testing == null)
  # the branch:Testing URL serves the Stable binary, so the Testing block
  # mirrors Stable.
  DL_PAGE="https://www.ocbase.com/download"
  UA="Mozilla/5.0 (X11; Linux x86_64)"

  NEXT_DATA=""
  for i in 1 2 3; do
    NEXT_DATA=$(curl -sfL -A "$UA" "$DL_PAGE" |
      sed -n 's|.*<script id="__NEXT_DATA__" type="application/json">\(.*\)</script>.*|\1|p') || NEXT_DATA=""
    [ -n "$NEXT_DATA" ] && break
    log "Retry $i/3 fetching $DL_PAGE (waiting $((2 ** i))s)..."
    sleep $((2 ** i))
  done
  if [ -z "$NEXT_DATA" ]; then
    warn "Failed to fetch the OCCT download page"
    output "updated" "false"
    exit 2
  fi

  PERSONAL=$(jq -e '[.props.pageProps.occtReleasesLinux[] | select(.edition == "Personal")][0]' <<<"$NEXT_DATA" 2>/dev/null) || {
    err "No Linux/Personal release entry in the download page data -- page format changed, fix this scraper"
    output "error_type" "version-detection"
    exit 1
  }
  STABLE_VERSION=$(jq -re '.stable.release.version.versionStr' <<<"$PERSONAL") || {
    err "No Stable version in the Linux/Personal release entry"
    output "error_type" "version-detection"
    exit 1
  }
  STABLE_SHA=$(jq -re '.stable.release.checksum' <<<"$PERSONAL" | tr '[:upper:]' '[:lower:]') || {
    err "No Stable checksum in the Linux/Personal release entry"
    output "error_type" "version-detection"
    exit 1
  }
  TESTING_VERSION=$(jq -re '.testing.release.version.versionStr // empty' <<<"$PERSONAL") || TESTING_VERSION=""
  TESTING_SHA=$(jq -re '.testing.release.checksum // empty' <<<"$PERSONAL" | tr '[:upper:]' '[:lower:]') || TESTING_SHA=""

  STABLE_SRI=$(nix hash convert --hash-algo sha256 --to sri "$STABLE_SHA") || {
    err "Published Stable checksum is not a sha256 hex digest: $STABLE_SHA"
    output "error_type" "version-detection"
    exit 1
  }
  TESTING_SRI=""
  if [ -n "$TESTING_VERSION" ]; then
    TESTING_SRI=$(nix hash convert --hash-algo sha256 --to sri "$TESTING_SHA") || {
      err "Published Testing checksum is not a sha256 hex digest: $TESTING_SHA"
      output "error_type" "version-detection"
      exit 1
    }
  fi

  # Set when the branch:Testing endpoint is observed serving the Stable binary
  # even though the page publishes a distinct Testing release.
  TESTING_SERVES_STABLE=""

  # sets EXPECT_VERSION/EXPECT_SHA/EXPECT_SRI for branch $1
  expect_for() {
    if [ "$1" = "Stable" ] || [ -z "$TESTING_VERSION" ] || [ -n "$TESTING_SERVES_STABLE" ]; then
      EXPECT_VERSION="$STABLE_VERSION" EXPECT_SHA="$STABLE_SHA" EXPECT_SRI="$STABLE_SRI"
    else
      EXPECT_VERSION="$TESTING_VERSION" EXPECT_SHA="$TESTING_SHA" EXPECT_SRI="$TESTING_SRI"
    fi
  }

  # sets BLOCK_START/CUR_VER/CUR_HASH for branch $1
  read_block() {
    BLOCK_START=$(grep -n "$1 = {" "$PACKAGE_FILE" | head -1 | cut -d: -f1)
    if [ -z "$BLOCK_START" ]; then
      err "Could not find $1 block in $PACKAGE_FILE"
      output "error_type" "version-detection"
      exit 1
    fi
    CUR_VER=$(tail -n +"$BLOCK_START" "$PACKAGE_FILE" | grep -oP 'version\s*=\s*"\K[^"]+' | head -1)
    CUR_HASH=$(tail -n +"$BLOCK_START" "$PACKAGE_FILE" | grep -oP 'hash\s*=\s*"\K[^"]+' | head -1)
  }

  # Phase 1: download + verify every branch that needs an update against the
  # published checksum. Nothing is written until every needed branch has
  # verified, so a failure here can never leave package.nix half-updated.
  NEED_UPDATE=""
  for BRANCH in Stable Testing; do
    expect_for "$BRANCH"
    read_block "$BRANCH"

    if [ "$CUR_VER" = "$EXPECT_VERSION" ] && [ "$CUR_HASH" = "$EXPECT_SRI" ]; then
      log "$BRANCH already up to date ($CUR_VER)"
      continue
    fi

    BRANCH_URL="https://www.ocbase.com/download-bin/edition:Personal/os:Linux/branch:$BRANCH"
    TMPBIN=$(mktemp "/tmp/occt-$BRANCH.XXXXXX")

    log "Downloading OCCT $BRANCH binary..."
    DOWNLOAD_OK=""
    for attempt in 1 2; do
      HTTP_CODE=$(curl -sL -w '%{http_code}' -o "$TMPBIN" "$BRANCH_URL" 2>/dev/null) || HTTP_CODE=""
      if [ "$HTTP_CODE" = "200" ] && [ "$(stat -c%s "$TMPBIN")" -ge 104857600 ]; then
        DOWNLOAD_OK=1
        break
      fi
      if [ "$attempt" -lt 2 ]; then
        log "$BRANCH download attempt $attempt failed (HTTP ${HTTP_CODE:-none}); retrying in 10s..."
        sleep 10
      fi
    done
    if [ -z "$DOWNLOAD_OK" ]; then
      warn "Failed to download a valid $BRANCH binary (HTTP 200, >=100MB)"
      rm -f "$TMPBIN"
      output "updated" "false"
      exit 2
    fi

    GOT_SHA=$(sha256sum "$TMPBIN" | cut -d' ' -f1)
    rm -f "$TMPBIN"
    if [ "$GOT_SHA" != "$EXPECT_SHA" ]; then
      # The published Testing metadata can lead the binary: when no separate
      # testing build is live the endpoint re-serves Stable. Identify what was
      # actually served from its hash instead of trusting the metadata, and
      # mirror Stable exactly as the testing == null path does.
      if [ "$BRANCH" = "Testing" ] && [ "$GOT_SHA" = "$STABLE_SHA" ]; then
        log "branch:Testing served the Stable binary ($STABLE_VERSION), not the published Testing $TESTING_VERSION -- mirroring Stable"
        TESTING_SERVES_STABLE=1
        expect_for "$BRANCH"
        read_block "$BRANCH"
        if [ "$CUR_VER" = "$EXPECT_VERSION" ] && [ "$CUR_HASH" = "$EXPECT_SRI" ]; then
          log "$BRANCH already up to date ($CUR_VER)"
          continue
        fi
      else
        err "$BRANCH checksum mismatch: page publishes $EXPECT_SHA, download is $GOT_SHA"
        output "error_type" "verification-error"
        exit 1
      fi
    fi
    NEED_UPDATE="$NEED_UPDATE $BRANCH"
  done

  # Phase 2: every needed branch verified; write version + hash per block.
  ANY_UPDATED="false"
  for BRANCH in $NEED_UPDATE; do
    expect_for "$BRANCH"
    read_block "$BRANCH"
    log "Updating $BRANCH: $CUR_VER -> $EXPECT_VERSION"
    ANY_UPDATED="true"

    VER_OFFSET=$(tail -n +"$BLOCK_START" "$PACKAGE_FILE" | grep -n 'version =' | head -1 | cut -d: -f1)
    VER_LINE=$((BLOCK_START + VER_OFFSET - 1))
    sed -i "${VER_LINE}s|version = \".*\"|version = \"${EXPECT_VERSION}\"|" "$PACKAGE_FILE"

    HASH_OFFSET=$(tail -n +"$BLOCK_START" "$PACKAGE_FILE" | grep -n 'hash =' | head -1 | cut -d: -f1)
    HASH_LINE=$((BLOCK_START + HASH_OFFSET - 1))
    sed -i "${HASH_LINE}s|hash = \".*\"|hash = \"${EXPECT_SRI}\"|" "$PACKAGE_FILE"
  done

  output "new_version" "$STABLE_VERSION"
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

  expect_for Testing
  log "OCCT update verified: ${STABLE_VERSION} (Stable), ${EXPECT_VERSION} (Testing)"
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
