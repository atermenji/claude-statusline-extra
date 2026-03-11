# Claude Code Usage Status Line

A status line extension for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that shows session info and API usage percentages.

<img width="1324" height="150" alt="CleanShot 2026-03-02 at 18 01 15@2x" src="https://github.com/user-attachments/assets/59367654-f4cf-44ac-abd3-82d1c84826fb" />


Shows model, cost, duration, context usage, tokens, and 5h/7d API usage with color indicators (🟢 < 50%, 🟡 50-80%, 🔴 > 80%). Usage data is fetched from the Anthropic API every 60 seconds and cached locally.

> **Note:** The Claude Code usage API is in private beta and may stop working.

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

## Configuration

Create `~/.claude/statusline.json` to customize which segments are shown and how they look. If the file doesn't exist, all segments are shown with default settings.

### Available segments

| Name | Description |
|------|-------------|
| `model` | Active model name (e.g. `[Claude 4 Sonnet]`) |
| `cost` | Session cost (e.g. `$1.23`) |
| `time` | Session duration (e.g. `12m 34s`) |
| `context` | Context window usage percentage |
| `5h` | 5-hour API usage with remaining time countdown (e.g. `3h 12m`) |
| `7d` | 7-day API usage with reset day (e.g. `Mon 3pm`) |
| `tokens` | Token counts (e.g. `42k in / 18k out`) |

### Segment options

| Option | Type | Description |
|--------|------|-------------|
| `color` | string | Named: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`. 256-color: `0`-`255`. Truecolor: `#RRGGBB` |
| `bold` | boolean | Bold text (`true` / `false`) |
| `emoji` | string \| boolean | `true` = auto circle (5h/7d only), `false` = none, or any string e.g. `"💰"` |
| `label` | string | Custom label text (e.g. `"ctx"`, `"weekly"`) |
| `reset` | boolean | Show reset countdown (5h/7d only) |

<details>
<summary><strong>Note:</strong> Color support varies across terminals.</summary>

Named colors (e.g. `red`, `cyan`) have the widest compatibility, 256-color codes (`0`–`255`) work in most modern terminals, and truecolor hex (`#RRGGBB`) requires 24-bit color support. If colors don't appear as expected, try a different format.
</details>

### Usage colors

The `5h` and `7d` segments are automatically colored based on usage percentage: red (≥ 80%), yellow (≥ 50%), green (< 50%). You can override these with a top-level `colors` object:

| Key | Default | Description |
|-----|---------|-------------|
| `high` | `red` | Color when usage ≥ 80% |
| `medium` | `yellow` | Color when usage ≥ 50% |
| `low` | `green` | Color when usage < 50% |

```json
{
  "colors": {
    "high": "196",
    "medium": "226",
    "low": "46"
  },
  "segments": ["5h", "7d"]
}
```

Accepts the same color formats as the segment `color` option: named, 256-color, or `#RRGGBB` hex.

### Examples

Minimal — just list segment names as strings to use defaults:

```json
{
  "segments": ["model", "cost", "5h"]
}
```

Customized — mix strings and objects:

```json
{
  "segments": [
    { "name": "model", "color": "cyan" },
    { "name": "cost", "color": "green", "emoji": "💰" },
    { "name": "context", "label": "ctx", "bold": true, "color": "#88aaff" },
    { "name": "5h", "emoji": true, "bold": true, "reset": true },
    { "name": "7d", "label": "weekly", "emoji": true, "bold": true, "reset": true, "color": 220 }
  ]
}
```

## Security

The installer verifies `statusline.sh` against an embedded SHA256 checksum. The script reads Claude Code OAuth credentials from the macOS Keychain to query the Anthropic usage API.

<details>
<summary><strong>Updating the checksum</strong> (contributors only)</summary>

When modifying `statusline.sh`, regenerate the checksum:

```bash
shasum -a 256 statusline.sh | cut -d ' ' -f 1
# Update EXPECTED_SHA256 in install.sh with the hash above
```
</details>
