#!/usr/bin/env bash

# Install native runtime dependencies for codex-cli.
#
# By default the script copies the sandbox binaries that are required at
# runtime. When called with the --full-native flag, it additionally
# bundles pre-built Rust CLI binaries so that the resulting npm package can run
# the native implementation when users set CODEX_RUST=1.
#
# Usage
#   install_native_deps.sh [RELEASE_ROOT] [--full-native]
#
# The optional RELEASE_ROOT is the path that contains package.json.  Omitting
# it installs the binaries into the repository's own bin/ folder to support
# local development.

set -euo pipefail

# ------------------
# Parse arguments
# ------------------

DEST_DIR=""
INCLUDE_RUST=0

for arg in "$@"; do
  case "$arg" in
    --full-native)
      INCLUDE_RUST=1
      ;;
    *)
      if [[ -z "$DEST_DIR" ]]; then
        DEST_DIR="$arg"
      else
        echo "Unexpected argument: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

# ----------------------------------------------------------------------------
# Determine where the binaries should be installed.
# ----------------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
  # The caller supplied a release root directory.
  CODEX_CLI_ROOT="$1"
  BIN_DIR="$CODEX_CLI_ROOT/bin"
else
  # No argument; fall back to the repo’s own bin directory.
  # Resolve the path of this script, then walk up to the repo root.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CODEX_CLI_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  BIN_DIR="$CODEX_CLI_ROOT/bin"
fi

# Make sure the destination directory exists.
mkdir -p "$BIN_DIR"

# ----------------------------------------------------------------------------
# Download and decompress the artifacts from the GitHub Actions workflow.
# ----------------------------------------------------------------------------

# Until we start publishing stable GitHub releases, we have to grab the binaries
# from the GitHub Action that created them. We'll try to get the latest successful
# rust-ci workflow run from the current repository.

# Determine the repository (default to current repo if in a git repository)
if git rev-parse --git-dir > /dev/null 2>&1; then
  REPO_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "$REPO_URL" =~ github\.com[:/]([^/]+)/([^/\.]+) ]]; then
    REPO_OWNER="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
  else
    REPO_OWNER="rileyseaburg"
    REPO_NAME="codex"
  fi
else
  REPO_OWNER="rileyseaburg"
  REPO_NAME="codex"
fi

echo "Looking for Rust artifacts in $REPO_OWNER/$REPO_NAME"

# Try to get the latest successful rust-ci workflow run
LATEST_RUN_ID=$(gh run list --repo "$REPO_OWNER/$REPO_NAME" --workflow rust-ci --status success --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")

if [[ -z "$LATEST_RUN_ID" ]]; then
  echo "⚠️  No successful rust-ci workflow runs found in $REPO_OWNER/$REPO_NAME"
  echo "⚠️  Falling back to prebuilt binaries from openai/codex"
  echo "⚠️  Note: This may not work if you don't have access to that repository"
  
  # Fallback to the original hardcoded workflow
  WORKFLOW_URL="https://github.com/openai/codex/actions/runs/15483730027"
  WORKFLOW_ID="${WORKFLOW_URL##*/}"
  REPO_FOR_DOWNLOAD="openai/codex"
else
  echo "✅ Found rust-ci workflow run: $LATEST_RUN_ID"
  WORKFLOW_ID="$LATEST_RUN_ID"
  REPO_FOR_DOWNLOAD="$REPO_OWNER/$REPO_NAME"
fi

ARTIFACTS_DIR="$(mktemp -d)"
trap 'rm -rf "$ARTIFACTS_DIR"' EXIT

# NB: The GitHub CLI `gh` must be installed and authenticated.
echo "Downloading artifacts from $REPO_FOR_DOWNLOAD run $WORKFLOW_ID"
if ! gh run download --dir "$ARTIFACTS_DIR" --repo "$REPO_FOR_DOWNLOAD" "$WORKFLOW_ID"; then
  echo "❌ Failed to download artifacts from $REPO_FOR_DOWNLOAD"
  echo "💡 This might be because:"
  echo "   - The workflow hasn't run successfully yet"
  echo "   - You don't have access to the repository"
  echo "   - The artifacts have expired"
  echo ""
  
  if [[ "$INCLUDE_RUST" -eq 1 ]]; then
    echo "❌ Cannot create native package without Rust binaries"
    echo "To fix this:"
    echo "   1. Make sure rust-ci workflow has run successfully in $REPO_OWNER/$REPO_NAME"
    echo "   2. Check that you have access to download artifacts"
    exit 1
  else
    echo "⚠️  Creating JavaScript-only package without sandbox binaries"
    echo "⚠️  Users will need to set CODEX_UNSAFE_ALLOW_NO_SANDBOX=1 to use this package"
    echo ""
    echo "To get a fully functional package:"
    echo "   1. Make sure rust-ci workflow has run successfully in $REPO_OWNER/$REPO_NAME"
    echo "   2. Check that you have access to download artifacts"
    
    # Create empty placeholder files so the package structure is consistent
    mkdir -p "$BIN_DIR"
    touch "$BIN_DIR/.sandbox-unavailable"
    
    echo "✅ Created JavaScript-only package (sandbox binaries unavailable)"
    exit 0
  fi
fi

# Decompress the artifacts for Linux sandboxing.
zstd -d "$ARTIFACTS_DIR/x86_64-unknown-linux-musl/codex-linux-sandbox-x86_64-unknown-linux-musl.zst" \
     -o "$BIN_DIR/codex-linux-sandbox-x64"

zstd -d "$ARTIFACTS_DIR/aarch64-unknown-linux-musl/codex-linux-sandbox-aarch64-unknown-linux-musl.zst" \
     -o "$BIN_DIR/codex-linux-sandbox-arm64"

if [[ "$INCLUDE_RUST" -eq 1 ]]; then
  # x64 Linux
  zstd -d "$ARTIFACTS_DIR/x86_64-unknown-linux-musl/codex-x86_64-unknown-linux-musl.zst" \
      -o "$BIN_DIR/codex-x86_64-unknown-linux-musl"
  # ARM64 Linux
  zstd -d "$ARTIFACTS_DIR/aarch64-unknown-linux-musl/codex-aarch64-unknown-linux-musl.zst" \
      -o "$BIN_DIR/codex-aarch64-unknown-linux-musl"
  # x64 macOS
  zstd -d "$ARTIFACTS_DIR/x86_64-apple-darwin/codex-x86_64-apple-darwin.zst" \
      -o "$BIN_DIR/codex-x86_64-apple-darwin"
  # ARM64 macOS
  zstd -d "$ARTIFACTS_DIR/aarch64-apple-darwin/codex-aarch64-apple-darwin.zst" \
      -o "$BIN_DIR/codex-aarch64-apple-darwin"
fi

echo "Installed native dependencies into $BIN_DIR"
