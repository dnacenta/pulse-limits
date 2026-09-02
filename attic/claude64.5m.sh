#!/usr/bin/env bash
# <swiftbar.title>CLAUDE 64</swiftbar.title>
# <swiftbar.version>v0.1.0</swiftbar.version>
# <swiftbar.author>Daniel Nacenta</swiftbar.author>
# <swiftbar.desc>Your Claude plan limits, rendered like a Commodore 64 boot screen.</swiftbar.desc>
# <swiftbar.dependencies>bash,jq,curl</swiftbar.dependencies>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# CLAUDE 64
# Reads the OAuth token Claude Code keeps in your Keychain, asks Anthropic's
# (undocumented) usage endpoint how much of your 5-hour and 7-day windows you
# have burned, and renders the answer like it is 1982.
# The only thing that leaves this Mac is one GET to api.anthropic.com.
#
# Works on the bash 3.2 that ships with macOS: no arrays-of-arrays, no ${x^^}.

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C

USAGE_URL="https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE="Claude Code-credentials"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude64"
CACHE="$CACHE_DIR/usage.json"
MIN_INTERVAL=90      # seconds between live calls; refreshOnOpen re-runs us often
BAR_WIDTH=20         # dropdown bars
TITLE_WIDTH=8        # menu bar bar

# --- palette: "light,dark" pairs, loosely the C64 colours -------------------
C_BLUE="#40318D,#8F87E6"
C_GREEN="#1E7F2A,#5FD75F"
C_AMBER="#A85E00,#FFB000"
C_RED="#B71C1C,#FF5C5C"
C_DIM="#707070,#8C8C8C"
MONO="font=Menlo size=12 trim=false"

# --- helpers -----------------------------------------------------------------
line() { printf '%s | %s\n' "$1" "$2"; }   # text, swiftbar params
sep()  { echo '---'; }
upper() { tr '[:lower:]' '[:upper:]'; }

bar() { # pct width -> "████░░░░"
  local pct=$1 width=$2 filled i out=""
  filled=$(( (pct * width + 50) / 100 ))
  (( filled > width )) && filled=$width
  (( filled < 0 )) && filled=0
  for (( i = 0; i < width; i++ )); do
    if (( i < filled )); then out="${out}█"; else out="${out}░"; fi
  done
  printf '%s' "$out"
}

tone() { # pct -> colour
  local p=$1
  if   (( p >= 85 )); then echo "$C_RED"
  elif (( p >= 60 )); then echo "$C_AMBER"
  else echo "$C_GREEN"; fi
}

epoch_of() { # ISO-8601 UTC ("2026-09-02T16:40:00.302649+00:00") -> epoch, or ""
  local s="${1%%.*}"; s="${s%%+*}"; s="${s%Z}"
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$s" +%s 2>/dev/null
}

countdown() { # epoch -> "2H 14M" / "4D 07H" / "38M"
  local diff=$(( $1 - $(date +%s) ))
  (( diff < 0 )) && diff=0
  local d=$(( diff / 86400 )) h=$(( diff % 86400 / 3600 )) m=$(( diff % 3600 / 60 ))
  if   (( d > 0 )); then printf '%dD %02dH' "$d" "$h"
  elif (( h > 0 )); then printf '%dH %02dM' "$h" "$m"
  else printf '%dM' "$m"; fi
}

clock_of() { date -r "$1" +"%a %H:%M" | upper; }

reset_line() { # iso -> "     RESETS IN 2H 14M (18:32)"
  local e; e=$(epoch_of "$1")
  if [[ -n "$e" ]]; then
    printf '     RESETS IN %s (%s)' "$(countdown "$e")" "$(clock_of "$e")"
  else
    printf '     RESETS ... UNKNOWN'
  fi
}

window_block() { # label pct resets_iso  -> the two-line bar block
  local label=$1 pct=$2 iso=$3
  line "$(printf '%-5s %s %3d%%' "$label" "$(bar "$pct" "$BAR_WIDTH")" "$pct")" "$MONO color=$(tone "$pct")"
  line "$(reset_line "$iso")" "$MONO color=$C_DIM"
}

c64_error() { # menubar-text error-name hint...
  local title=$1 err=$2; shift 2
  line "$title" "$MONO color=$C_RED"
  sep
  line '    **** CLAUDE 64 USAGE V2 ****' "$MONO color=$C_BLUE"
  sep
  line "?$err  ERROR" "$MONO color=$C_RED"
  local h; for h in "$@"; do line "$h" "$MONO color=$C_DIM"; done
  sep
  line 'LOAD "RETRY",8,1' "$MONO color=$C_GREEN refresh=true"
  line 'READY.' "$MONO color=$C_GREEN"
  exit 0
}

# --- SYS 64738: the C64 soft-reset. Drops the cache so the next run is live. --
if [[ "${1:-}" == "--reset" ]]; then
  rm -f "$CACHE"
  exit 0
fi

mkdir -p "$CACHE_DIR"
now=$(date +%s)

# --- 1. credentials from the Keychain item Claude Code owns -------------------
creds=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) \
  || c64_error 'C64 ??' 'DEVICE NOT PRESENT' \
       'NO CLAUDE CODE LOGIN IN THE KEYCHAIN' \
       'RUN  claude  IN A TERMINAL AND LOG IN'

token=""; expires_ms=0; plan="?"; tier="?"
read -r token expires_ms plan tier < <(
  jq -r '.claudeAiOauth | [ (.accessToken // ""), (.expiresAt // 0),
                           (.subscriptionType // "?"), (.rateLimitTier // "?") ] | @tsv' \
     <<<"$creds" 2>/dev/null
)
[[ -n "$token" ]] || c64_error 'C64 ??' 'DEVICE NOT PRESENT' \
  'KEYCHAIN ITEM HAS NO ACCESS TOKEN' 'RUN  claude  AND LOG IN AGAIN'

# "default_claude_max_20x" -> "MAX 20X"; fall back to the plan name
plan_label=$(printf '%s' "$tier" | sed 's/^default_claude_//; s/_/ /g' | upper)
[[ "$tier" == "?" ]] && plan_label=$(printf '%s' "$plan" | upper)

# --- 2. usage: fresh cache, else one live call ---------------------------------
status=""     # empty = fine, otherwise a C64-style error name
source="CACHE"
cache_age=999999
[[ -f "$CACHE" ]] && cache_age=$(( now - $(stat -f %m "$CACHE") ))

# We read the Keychain fresh every run, so if Claude Code rotated the token
# since last time we already hold the new one. The server decides if it is
# expired (401), not the local expiresAt, which only Claude Code keeps current.
if (( cache_age > MIN_INTERVAL )); then
  tmp=$(mktemp "$CACHE_DIR/usage.XXXXXX")
  code=$(curl -sS -m 15 -o "$tmp" -w '%{http_code}' \
           -H "Authorization: Bearer $token" \
           -H "anthropic-beta: oauth-2025-04-20" \
           -H "User-Agent: claude64-swiftbar/0.1" \
           "$USAGE_URL" 2>/dev/null) || code=000
  case "$code" in
    200) if jq -e '.five_hour' "$tmp" >/dev/null 2>&1; then
           mv -f "$tmp" "$CACHE"; source="LIVE"; cache_age=0
         else status="BAD RESPONSE"; fi ;;
    401|403) status="TOKEN EXPIRED" ;;
    429)     status="TOO MANY REQUESTS" ;;
    000)     status="NETWORK" ;;
    *)       status="HTTP $code" ;;
  esac
  rm -f "$tmp"
fi

if [[ ! -f "$CACHE" ]]; then
  case "$status" in
    "TOKEN EXPIRED") c64_error 'C64 !!' "$status" \
      'THE KEYCHAIN TOKEN HAS EXPIRED' 'OPEN CLAUDE CODE ONCE, IT REFRESHES IT' ;;
    *) c64_error 'C64 !!' "${status:-NO DATA}" 'COULD NOT REACH API.ANTHROPIC.COM' ;;
  esac
fi

# --- 3. pull the numbers out of the JSON --------------------------------------
s_pct=0; s_reset="-"; w_pct=0; w_reset="-"
read -r s_pct s_reset w_pct w_reset < <(
  jq -r '[ ((.five_hour.utilization // 0) + 0.5 | floor), (.five_hour.resets_at // "-"),
           ((.seven_day.utilization // 0) + 0.5 | floor), (.seven_day.resets_at // "-") ] | @tsv' \
     "$CACHE"
)
free_pct=$(( 100 - s_pct )); (( free_pct < 0 )) && free_pct=0

# --- 4. render ----------------------------------------------------------------
title="$(bar "$s_pct" "$TITLE_WIDTH") ${s_pct}%"
title_color=$(tone "$s_pct")
if [[ -n "$status" ]]; then title="$title !"; title_color=$C_RED; fi
line "$title" "$MONO color=$title_color"
sep

line '    **** CLAUDE 64 USAGE V2 ****' "$MONO color=$C_BLUE"
# Hold Option and the header becomes SYS 64738, the C64 reset vector: it drops
# the cache and forces a live call. Hidden so the screen stays a boot screen.
line 'SYS 64738' "$MONO color=$C_GREEN alternate=true bash=$0 param1=--reset terminal=false refresh=true"
line " $(printf '%s SYSTEM  %d%% SESSION BYTES FREE' "$plan_label" "$free_pct")" "$MONO color=$C_BLUE"
sep

if [[ -n "$status" ]]; then
  line "?$status  ERROR" "$MONO color=$C_RED"
  line "SHOWING LAST GOOD READING, $(countdown $(( now + cache_age )) | sed 's/^0M$/UNDER 1M/') AGO" "$MONO color=$C_DIM"
  sep
fi

line 'READY.' "$MONO color=$C_GREEN"
line 'LOAD "SESSION",8,1' "$MONO color=$C_DIM"
window_block "5H" "$s_pct" "$s_reset"
line 'LOAD "WEEKLY",8,1' "$MONO color=$C_DIM"
window_block "7D" "$w_pct" "$w_reset"

# per-model weekly caps, when the plan has them (e.g. a Fable-only weekly limit)
while IFS=$'\t' read -r name pct iso; do
  [[ -n "${name:-}" ]] || continue
  window_block "$(printf '%.5s' "$(printf '%s' "$name" | upper)")" "$pct" "$iso"
done < <(
  jq -r '.limits[]? | select(.kind == "weekly_scoped")
         | [ (.scope.model.display_name // .scope.surface // "SCOPED"), (.percent // 0), (.resets_at // "-") ] | @tsv' \
     "$CACHE" 2>/dev/null
)

# extra usage credits: only worth a line once you have actually spent some
credits=$(jq -r '.extra_usage | select(.is_enabled == true and (.used_credits // 0) > 0)
                 | [ .used_credits, (.currency // "") ] | @tsv' "$CACHE" 2>/dev/null)
if [[ -n "$credits" ]]; then
  IFS=$'\t' read -r used cur <<<"$credits"
  line "$(printf 'CREDITS  %.2f %s USED' "$used" "$cur")" "$MONO color=$C_AMBER"
fi

