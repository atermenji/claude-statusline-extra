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

fmt_reset() {
  local reset_utc="$1"
  [ -z "$reset_utc" ] || [ "$reset_utc" = "null" ] && return
  local epoch
  epoch=$(date -juf "%Y-%m-%d %H:%M:%S" "$reset_utc" "+%s" 2>/dev/null) || return
  date -jf "%s" "$epoch" "+%a %-I%p" 2>/dev/null | sed 's/AM/am/;s/PM/pm/'
}

USAGE=""
if [ -f "$CACHE" ]; then
  IFS=$'\t' read -r five_hour_pct five_hour_reset seven_day_pct seven_day_reset < <(
    jq -r '[.five_hour_pct // "", .five_hour_reset // "", .seven_day_pct // "", .seven_day_reset // ""] | @tsv' "$CACHE" 2>/dev/null
  )

  BOLD=$'\033[1m'
  RESET=$'\033[0m'
  if [ -n "$five_hour_pct" ]; then
    RESET_5H=""
    if [ -n "$five_hour_reset" ] && [ "$five_hour_reset" != "null" ]; then
      reset_epoch=$(date -juf "%Y-%m-%d %H:%M:%S" "$five_hour_reset" "+%s" 2>/dev/null) || true
      if [ -n "$reset_epoch" ]; then
        remaining=$(( reset_epoch - $(date +%s) ))
        if [ "$remaining" -gt 0 ]; then
          RESET_5H=" ($(( remaining / 3600 ))h $(( (remaining % 3600) / 60 ))m)"
        fi
      fi
    fi
    USAGE=" | $(usage_emoji "$five_hour_pct") 5h: ${BOLD}${five_hour_pct}%${RESET}${RESET_5H}"
  fi
  if [ -n "$seven_day_pct" ]; then
    RESET_FMT=$(fmt_reset "${seven_day_reset:-}")
    RESET_PART=""
    [ -n "$RESET_FMT" ] && RESET_PART=" (${RESET_FMT})"
    SEP=""
    [ -n "$USAGE" ] && SEP=" |"
    USAGE="${USAGE}${SEP} $(usage_emoji "$seven_day_pct") weekly: ${BOLD}${seven_day_pct}%${RESET}${RESET_PART}"
  fi
fi

echo "[$MODEL] $COST_FMT | $TIME_FMT | ctx: ${USED}%${USAGE} | ${IN_K}k in / ${OUT_K}k out"
