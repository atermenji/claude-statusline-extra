# Claude Code Usage Status Line

A status line extension for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that shows session info and API usage percentages.

<img width="1358" height="64" alt="CleanShot 2026-02-25 at 13 04 04@2x" src="https://github.com/user-attachments/assets/f76a1f75-693b-4a82-9eeb-faa7f736fd79" />


Shows: model name, session cost, duration, context window usage, token counts, 5-hour and 7-day API usage with color indicators (🟢 < 50%, 🟡 50-80%, 🔴 > 80%) and next reset time.

Usage data is fetched from the Anthropic API in the background every 60 seconds and cached locally.

**Note** Claude Code usage API is a private beta and may stop working.

## Requirements

- **macOS** (uses Keychain for credential access)
- **jq** (`brew install jq`)
- **curl**
- **Claude Code** (logged in at least once so credentials exist in Keychain)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/atermenji/claude-statusline-extra/master/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/atermenji/claude-statusline-extra.git
cd claude-statusline-extra
./install.sh
```

The installer will:
1. Download `statusline.sh` and verify its SHA256 checksum
2. Install it to `~/.claude/statusline.sh`
3. Configure `~/.claude/settings.json` with the statusLine entry

Restart Claude Code after installation.

## Uninstall

```bash
./uninstall.sh
```

## Security

The installer verifies the downloaded `statusline.sh` against an embedded SHA256 checksum before installation.
The `statusline.sh` script reads Claude Code OAuth credentials from the macOS Keychain to query the Anthropic usage API.

## Updating the checksum

When modifying `statusline.sh`, regenerate the checksum files:

```bash
shasum -a 256 statusline.sh | cut -d ' ' -f 1
# Update EXPECTED_SHA256 in install.sh with the hash above
```
