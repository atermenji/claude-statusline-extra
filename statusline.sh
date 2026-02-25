#!/bin/bash
umask 077
input=$(cat)

CACHE="$HOME/.claude/usage_cache.json"
CACHE_MAX_AGE=60

# ── Background usage fetch (non-blocking) ────────────────────────

refresh_usage() {
  # Atomic lock via mkdir to prevent concurrent fetches
  LOCK="${CACHE}.lock"
  # Remove stale lock from a previous crash (older than 120s)
  if [ -d "$LOCK" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    [ "$LOCK_AGE" -gt 120 ] && rmdir "$LOCK" 2>/dev/null
  fi
  if ! mkdir "$LOCK" 2>/dev/null; then return; fi
  trap 'rmdir "$LOCK" 2>/dev/null' RETURN

  RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return

  # Use jq for robust JSON parsing instead of fragile sed regex
  TOKEN=$(echo "$RAW" | jq -r '(.claudeAiOauth.accessToken // .accessToken) // empty' 2>/dev/null)
  [ -z "$TOKEN" ] && return

  # Pass auth header via stdin (--config -) so the token doesn't appear in ps output
  BODY=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | \
    curl -s --max-time 10 \
      -H "Accept: application/json" \
      -H "anthropic-beta: oauth-2025-04-20" \
      --config - \
      "https://api.anthropic.com/api/oauth/usage") || return

  # Validate response contains expected data before caching
  if ! echo "$BODY" | jq -e '.five_hour' >/dev/null 2>&1; then return; fi

  # Atomic write: write to temp file then mv to prevent partial reads
  TMP_CACHE=$(mktemp "${CACHE}.XXXXXX")
  chmod 600 "$TMP_CACHE"
  if echo "$BODY" | jq -c '{
    five_hour_pct: (if .five_hour.utilization then (.five_hour.utilization * 10 | round / 10) else null end),
    five_hour_reset: (.five_hour.resets_at // null | if . then split(".")[0] | split("+")[0] | gsub("T"; " ") else null end),
    seven_day_pct: (if .seven_day.utilization then (.seven_day.utilization * 10 | round / 10) else null end),
    seven_day_reset: (.seven_day.resets_at // null | if . then split(".")[0] | split("+")[0] | gsub("T"; " ") else null end),
    fetched_at: (now | floor)
  }' > "$TMP_CACHE" 2>/dev/null; then
    mv "$TMP_CACHE" "$CACHE"
  else
    rm -f "$TMP_CACHE"
  fi
}

# Refresh cache in background if stale or missing
if [ ! -f "$CACHE" ] || [ $(($(date +%s) - $(stat -f %m "$CACHE"))) -gt $CACHE_MAX_AGE ]; then
  refresh_usage &
fi

# ── Format session info from Claude Code JSON ────────────────────

IFS=$'\t' read -r MODEL COST DURATION_MS USED IN_K OUT_K < <(
  echo "$input" | jq -r '[
    .model.display_name,
    (.cost.total_cost_usd // 0 | tostring),
    (.cost.total_duration_ms // 0 | tostring),
    (.context_window.used_percentage // 0 | tostring),
    ((.context_window.total_input_tokens // 0) / 1000 | floor | tostring),
    ((.context_window.total_output_tokens // 0) / 1000 | floor | tostring)
  ] | @tsv'
)

COST_FMT=$(printf '$%.2f' "$COST")

DURATION_SEC=$((DURATION_MS / 1000))
HOURS=$((DURATION_SEC / 3600))
MINS=$(( (DURATION_SEC % 3600) / 60 ))
SECS=$((DURATION_SEC % 60))
if [ "$HOURS" -gt 0 ]; then
  TIME_FMT="${HOURS}h ${MINS}m"
else
  TIME_FMT="${MINS}m ${SECS}s"
fi

# ── Format usage from cache ──────────────────────────────────────

usage_emoji() {
  local pct="${1%.*}"
  pct="${pct:-0}"
  if [ "$pct" -ge 80 ]; then   echo "🔴"
  elif [ "$pct" -ge 50 ]; then echo "🟡"
  else                          echo "🟢"
  fi
}

usage_color() {
  local pct="${1%.*}"
  pct="${pct:-0}"
  if [ "$pct" -ge 80 ]; then   echo "196"
  elif [ "$pct" -ge 50 ]; then echo "226"
  else                          echo "46"
  fi
}

fmt_reset() {
  local reset_utc="$1"
  [ -z "$reset_utc" ] || [ "$reset_utc" = "null" ] && return
  local epoch
  epoch=$(date -juf "%Y-%m-%d %H:%M:%S" "$reset_utc" "+%s" 2>/dev/null) || return
  date -jf "%s" "$epoch" "+%a %-I%p" 2>/dev/null | sed 's/AM/am/;s/PM/pm/'
}

five_hour_pct=""
five_hour_reset=""
seven_day_pct=""
seven_day_reset=""
if [ -f "$CACHE" ]; then
  IFS=$'\t' read -r five_hour_pct five_hour_reset seven_day_pct seven_day_reset < <(
    jq -r '[.five_hour_pct // "", .five_hour_reset // "", .seven_day_pct // "", .seven_day_reset // ""] | @tsv' "$CACHE" 2>/dev/null
  )
fi

# ── Styling helpers ───────────────────────────────────────────────

stylize() {
  local text="$1" do_bold="$2" color="$3"
  local codes=""
  [ "$do_bold" = "true" ] && codes="1"
  case "$color" in
    red) codes="${codes:+$codes;}31" ;; green) codes="${codes:+$codes;}32" ;;
    yellow) codes="${codes:+$codes;}33" ;; blue) codes="${codes:+$codes;}34" ;;
    magenta) codes="${codes:+$codes;}35" ;; cyan) codes="${codes:+$codes;}36" ;;
    white) codes="${codes:+$codes;}37" ;;
    \#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      # Truecolor hex: #RRGGBB
      local hex="${color#\#}"
      local r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))
      codes="${codes:+$codes;}38;2;${r};${g};${b}" ;;
    [0-9]|[0-9][0-9]|[12][0-9][0-9])
      # 256-color: 0-255
      codes="${codes:+$codes;}38;5;${color}" ;;
  esac
  if [ -n "$codes" ]; then
    printf '\033[%sm%s\033[0m' "$codes" "$text"
  else
    printf '%s' "$text"
  fi
}

custom_emoji_prefix() {
  local val="$1"
  [ -n "$val" ] && [ "$val" != "true" ] && [ "$val" != "false" ] && printf '%s ' "$val"
}

# ── Segment formatting functions ─────────────────────────────────
# All receive: $1=label $2=emoji $3=bold $4=reset $5=color

fmt_seg_model() {
  local do_emoji="$2" do_bold="${3:-false}" color="$5"
  printf '%s%s' "$(custom_emoji_prefix "$do_emoji")" "$(stylize "[$MODEL]" "$do_bold" "$color")"
}

fmt_seg_cost() {
  local do_emoji="$2" do_bold="${3:-false}" color="$5"
  printf '%s%s' "$(custom_emoji_prefix "$do_emoji")" "$(stylize "$COST_FMT" "$do_bold" "$color")"
}

fmt_seg_time() {
  local do_emoji="$2" do_bold="${3:-false}" color="$5"
  printf '%s%s' "$(custom_emoji_prefix "$do_emoji")" "$(stylize "$TIME_FMT" "$do_bold" "$color")"
}

fmt_seg_context() {
  local label="${1:-ctx}" do_emoji="$2" do_bold="${3:-false}" color="$5"
  printf '%s%s: %s' "$(custom_emoji_prefix "$do_emoji")" "$label" "$(stylize "${USED}%" "$do_bold" "$color")"
}

fmt_seg_5h() {
  local label="${1:-5h}" do_emoji="${2:-true}" do_bold="${3:-true}" do_reset="${4:-true}" color="$5"
  [ -z "$five_hour_pct" ] && return
  [ -z "$color" ] && color=$(usage_color "$five_hour_pct")
  local val=$(stylize "${five_hour_pct}%" "$do_bold" "$color")
  local reset_part=""
  if [ "$do_reset" = "true" ] && [ -n "$five_hour_reset" ] && [ "$five_hour_reset" != "null" ]; then
    local reset_epoch
    reset_epoch=$(date -juf "%Y-%m-%d %H:%M:%S" "$five_hour_reset" "+%s" 2>/dev/null) || true
    if [ -n "$reset_epoch" ]; then
      local remaining=$(( reset_epoch - $(date +%s) ))
      if [ "$remaining" -gt 0 ]; then
        reset_part=" ($(( remaining / 3600 ))h $(( (remaining % 3600) / 60 ))m)"
      fi
    fi
  fi
  local emoji_part=""
  if [ "$do_emoji" = "true" ]; then
    emoji_part="$(usage_emoji "$five_hour_pct") "
  elif [ "$do_emoji" != "false" ] && [ -n "$do_emoji" ]; then
    emoji_part="$do_emoji "
  fi
  printf '%s%s: %s%s' "$emoji_part" "$label" "$val" "$reset_part"
}

fmt_seg_7d() {
  local label="${1:-weekly}" do_emoji="${2:-true}" do_bold="${3:-true}" do_reset="${4:-true}" color="$5"
  [ -z "$seven_day_pct" ] && return
  [ -z "$color" ] && color=$(usage_color "$seven_day_pct")
  local val=$(stylize "${seven_day_pct}%" "$do_bold" "$color")
  local reset_part=""
  if [ "$do_reset" = "true" ]; then
    local reset_fmt
    reset_fmt=$(fmt_reset "${seven_day_reset:-}")
    [ -n "$reset_fmt" ] && reset_part=" (${reset_fmt})"
  fi
  local emoji_part=""
  if [ "$do_emoji" = "true" ]; then
    emoji_part="$(usage_emoji "$seven_day_pct") "
  elif [ "$do_emoji" != "false" ] && [ -n "$do_emoji" ]; then
    emoji_part="$do_emoji "
  fi
  printf '%s%s: %s%s' "$emoji_part" "$label" "$val" "$reset_part"
}

fmt_seg_tokens() {
  local do_emoji="$2" do_bold="${3:-false}" color="$5"
  printf '%s%s' "$(custom_emoji_prefix "$do_emoji")" "$(stylize "${IN_K}k in / ${OUT_K}k out" "$do_bold" "$color")"
}

# ── Read config ──────────────────────────────────────────────────

CONFIG="$HOME/.claude/statusline.json"
DEFAULT_SEG_LIST="model cost time context 5h 7d tokens"

DEFAULTS_CONFIG="$HOME/.claude/statusline.defaults.json"
DEFAULT_JSON='{
  "_options": {
    "color": "named: red/green/yellow/blue/magenta/cyan/white, 256-color: 0-255, or truecolor: #RRGGBB",
    "bold": "true or false",
    "emoji": "true = auto circle (5h/7d only), false = none, or any string e.g. \"💰\", \"🔋\", \"⏱️\"",
    "label": "custom label text, e.g. \"ctx\", \"weekly\", \"session\"",
    "reset": "true or false — show reset countdown (5h/7d only)"
  },
  "segments": [
    { "name": "model", "bold": false, "color": "", "emoji": "" },
    { "name": "cost", "bold": false, "color": "", "emoji": "" },
    { "name": "time", "bold": false, "color": "", "emoji": "" },
    { "name": "context", "label": "ctx", "bold": false, "color": "", "emoji": "" },
    { "name": "5h", "label": "5h", "emoji": true, "bold": true, "reset": true, "color": "" },
    { "name": "7d", "label": "weekly", "emoji": true, "bold": true, "reset": true, "color": "" },
    { "name": "tokens", "bold": false, "color": "", "emoji": "" }
  ]
}'
USER_JSON='{
  "segments": [
    "model",
    "cost",
    "time",
    { "name": "context", "label": "ctx" },
    { "name": "5h", "emoji": true, "bold": true, "reset": true },
    { "name": "7d", "label": "weekly", "emoji": true, "bold": true, "reset": true },
    "tokens"
  ]
}'

printf '%s\n' "$DEFAULT_JSON" > "$DEFAULTS_CONFIG"
[ ! -f "$CONFIG" ] && printf '%s\n' "$USER_JSON" > "$CONFIG"

SEG_CONFIG=""
if [ -f "$CONFIG" ]; then
  SEG_CONFIG=$(jq -r '
    def optstr: if . == null then "" elif type == "boolean" then (if . then "true" else "false" end) else tostring end;
    def D: "\u001f";
    .segments // [] | .[] |
    if type == "string" then "\(.)" + D + D + D + D + D
    else "\(.name)" + D + "\(.label // "")" + D + "\(.emoji | optstr)" + D + "\(.bold | optstr)" + D + "\(.reset | optstr)" + D + "\(.color // "")"
    end
  ' "$CONFIG" 2>/dev/null)
fi

if [ -z "$SEG_CONFIG" ]; then
  SEG_CONFIG=""
  for s in $DEFAULT_SEG_LIST; do
    SEG_CONFIG="${SEG_CONFIG}${s}$(printf '\x1f\x1f\x1f\x1f\x1f')
"
  done
fi

# ── Build output ─────────────────────────────────────────────────

OUTPUT=""
while IFS=$'\x1f' read -r seg_name seg_label seg_emoji seg_bold seg_reset seg_color _; do
  [ -z "$seg_name" ] && continue
  PART=""
  case "$seg_name" in
    model)   PART=$(fmt_seg_model "" "$seg_emoji" "$seg_bold" "" "$seg_color") ;;
    cost)    PART=$(fmt_seg_cost "" "$seg_emoji" "$seg_bold" "" "$seg_color") ;;
    time)    PART=$(fmt_seg_time "" "$seg_emoji" "$seg_bold" "" "$seg_color") ;;
    context) PART=$(fmt_seg_context "$seg_label" "$seg_emoji" "$seg_bold" "" "$seg_color") ;;
    5h)      PART=$(fmt_seg_5h "$seg_label" "$seg_emoji" "$seg_bold" "$seg_reset" "$seg_color") ;;
    7d)      PART=$(fmt_seg_7d "$seg_label" "$seg_emoji" "$seg_bold" "$seg_reset" "$seg_color") ;;
    tokens)  PART=$(fmt_seg_tokens "" "$seg_emoji" "$seg_bold" "" "$seg_color") ;;
  esac
  [ -n "$PART" ] && OUTPUT="${OUTPUT:+$OUTPUT | }$PART"
done <<< "$SEG_CONFIG"

echo "$OUTPUT"
