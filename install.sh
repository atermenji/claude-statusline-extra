#!/bin/bash
# Claude Code Usage Status Line — Installer
#
# Shows session info and 5-hour / 7-day usage percentages in the Claude Code
# status line. Refreshes usage data from the Anthropic API every 60s in the
# background, triggered by the status line itself (no daemon needed).
#
# Requirements: macOS, jq, curl, Claude Code (logged in at least once)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/atermenji/claude-statusline-extra/master/install.sh | bash

set -euo pipefail

main() {

STATUSLINE_SCRIPT="$HOME/.claude/statusline.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

# ── Download configuration ─────────────────────────────────────────
REPO_RAW_URL="https://raw.githubusercontent.com/atermenji/claude-statusline-extra/master"
STATUSLINE_URL="${REPO_RAW_URL}/statusline.sh"
# SHA256 of the statusline.sh this installer version expects.
# Update this hash whenever statusline.sh changes:
#   shasum -a 256 statusline.sh | cut -d ' ' -f 1
EXPECTED_SHA256="4cc2c5cdcfa02010ba65e78bc12f95d740138f389cb5de1ec50affaeb4c1f479"

# ── Preflight checks ──────────────────────────────────────────────

if [ "$(uname)" != "Darwin" ]; then
  echo "Error: This script is macOS-only (uses Keychain)." >&2
  return 1
fi

for cmd in jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required. Install with: brew install $cmd" >&2
    return 1
  fi
done

if ! command -v shasum &>/dev/null; then
  echo "Error: shasum is required for checksum verification." >&2
  return 1
fi

if ! security find-generic-password -s "Claude Code-credentials" -w &>/dev/null; then
  echo "Error: No Claude Code credentials found in Keychain." >&2
  echo "Make sure Claude Code is installed and you've logged in at least once." >&2
  return 1
fi

# ── SHA256 helpers ─────────────────────────────────────────────────

compute_sha256() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    echo "Error: No SHA256 tool found." >&2
    return 1
  fi
}

verify_checksum() {
  local file="$1"
  local expected="$2"
  local actual
  actual=$(compute_sha256 "$file") || return 1

  if [ "$actual" != "$expected" ]; then
    echo "Error: SHA256 checksum mismatch!" >&2
    echo "  Expected: $expected" >&2
    echo "  Got:      $actual" >&2
    echo "" >&2
    echo "The downloaded statusline.sh does not match the expected version." >&2
    echo "This could indicate tampering or a version mismatch." >&2
    return 1
  fi
}

# ── Download and install statusline.sh ─────────────────────────────

mkdir -p "$(dirname "$STATUSLINE_SCRIPT")"

TMP_DOWNLOAD=$(mktemp "${STATUSLINE_SCRIPT}.XXXXXX")
cleanup() { rm -f "$TMP_DOWNLOAD"; }
trap cleanup EXIT

echo "Downloading statusline.sh..."

if ! curl \
  --proto '=https' --tlsv1.2 \
  --silent --show-error --fail \
  --location --max-redirs 3 \
  --max-time 30 --connect-timeout 10 \
  --retry 2 --retry-delay 1 \
  --output "$TMP_DOWNLOAD" \
  "$STATUSLINE_URL"; then
  echo "Error: Failed to download statusline.sh from:" >&2
  echo "  $STATUSLINE_URL" >&2
  return 1
fi

if [ ! -s "$TMP_DOWNLOAD" ]; then
  echo "Error: Downloaded file is empty." >&2
  return 1
fi

verify_checksum "$TMP_DOWNLOAD" "$EXPECTED_SHA256" || return 1
echo "Checksum verified."

mv "$TMP_DOWNLOAD" "$STATUSLINE_SCRIPT"
trap - EXIT
chmod 700 "$STATUSLINE_SCRIPT"
echo "Installed $STATUSLINE_SCRIPT"

# ── Configure Claude Code settings ────────────────────────────────

if [ -f "$SETTINGS_FILE" ]; then
  if jq -e '.statusLine' "$SETTINGS_FILE" >/dev/null 2>&1; then
    echo ""
    echo "Note: ~/.claude/settings.json already has a statusLine entry."
    echo "Make sure it points to: ~/.claude/statusline.sh"
  else
    UPDATED=$(jq '. + {"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}' "$SETTINGS_FILE")
    echo "$UPDATED" > "$SETTINGS_FILE"
    echo "Updated ~/.claude/settings.json with statusLine config"
  fi
else
  cat > "$SETTINGS_FILE" << 'SETTINGS_EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
SETTINGS_EOF
  echo "Created ~/.claude/settings.json with statusLine config"
fi

# ── Done ──────────────────────────────────────────────────────────

echo ""
echo "Done! Restart Claude Code to see usage in the status line."
echo "The status bar will show:  [Model] \$cost | time | ctx: N% | Nk in / Nk out | 5h: N% 7d: N%"
echo ""
echo "To uninstall:"
echo "  curl -fsSL ${REPO_RAW_URL}/uninstall.sh | bash"

}

main "$@"
