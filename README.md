# PulseLimits

Your Claude plan limits in the macOS menu bar, as a retro patient monitor.
The ECG's heart rate is your session usage: an idle account beats at ~50 BPM,
a maxed-out one races at ~180. One Bash script and one HTML file, driven by
SwiftBar. No app of its own, no account, no server.

    63% ◔                <- menu bar: the 5-hour window, battery-style

Left-click opens the monitor in a borderless popover. Right-click opens a
plain text fallback menu.

## Themes

Right-click the menu bar item, open **THEME**, pick one. The choice is
saved in `~/.config/pulse-limits/theme` (or `./pulse-limits.5m.sh --theme
synth` from a terminal). The data and the animation are shared.

- `crt`     phosphor patient monitor, scanlines, 5x7 pixel font (default)
- `modern`  a macOS widget: system font, cards, follows light/dark mode
- `cyber`   neon HUD: chamfered panels, chromatic-aberration digits, hex stream
- `term`    a Nord-palette TUI: box drawing, `[|||...]` meters, block-char trend
- `synth`   synthwave: sunset, perspective grid, the trend as a skyline
- `analog`  VU meter and round gauges on cream dials, chart-recorder strip
            (no trend in this one)

Preview any of them without SwiftBar by adding `?theme=<name>` before the
`#` in the page URL (see the last section).

## What the monitor shows

- **Session panel**: the heartbeat on the left, its rate set by what Claude
  Code is doing right now: `2.4K TOK/MIN · 3 SESSIONS` and a fast beat while
  replies are streaming, `IDLE 45M` and a slow one when nothing is going on.
  The big percentage and reset countdown on the right; a bar along the
  bottom filled to the same percentage. Green, amber from 60 %, red from
  85 %. Amber when the data is stale, a flat line with `NO SIGNAL` when
  there is none.
- **Rings**: one per remaining window (WEEK, plus any per-model weekly cap
  the plan carries), percentage inside, reset countdown under it.
- **Trend**: the last 12 hours of session usage, one bar per ~20 minutes.
- **Footer**: when the data was fetched, the next reset, extra-usage credits
  once you have spent any, and the error with the age of the last good
  reading when something is wrong.

## How it works

1. `security find-generic-password -s "Claude Code-credentials" -w` reads the
   OAuth token Claude Code already keeps in your Keychain. The same item
   carries `subscriptionType` and `rateLimitTier`, which is where the plan
   label comes from.
2. One `GET https://api.anthropic.com/api/oauth/usage` with that bearer token
   and the header `anthropic-beta: oauth-2025-04-20`. This is the call behind
   `/usage` in Claude Code. It is undocumented, so it can change without
   notice; when it does the monitor shows an error instead of wrong numbers.
3. The JSON is cached in `~/.cache/pulse-limits/usage.json`, and every live
   reading appends a row to `history.tsv` for the trend strip. Live calls are
   at most one per 90 s; the plugin re-runs every 5 min.
4. The script packs the numbers as base64 JSON into the URL fragment of
   `panel.html` and writes that URL to `~/.cache/pulse-limits/panel.url`.
   The page reads `location.hash`, draws everything on a canvas, and
   animates the trace. Countdowns tick live in the page.
   While the panel is open the helper runs `pulse-limits.5m.sh --payload`
   on show and every 60 s (a fresh fetch, JSON only, throttled to one call
   per 20 s) and hands the result to `window.pulse.usage(...)`, so the
   numbers update in place and the header says `● LIVE` whenever the
   reading is under two minutes old. The API is only polled that often
   while you are looking.
5. `bin/pulse-menubar` draws the menu bar item as one image, text then ring,
   like the battery indicator: 2x PNG, one per menu bar appearance, put on
   the title line with `image=… width=W height=18`. Without it the title
   falls back to plain text.
6. A click runs `open-monitor.sh`, which shows `bin/pulse-popover`: a
   small Swift program with one WKWebView in a borderless, non-activating
   panel under the mouse. It hides on a click outside, Escape, or a second
   click on the icon. It stays resident, page unloaded, so the next click
   shows it in ~50 ms instead of the ~400 ms WebKit needs to start; after
   10 idle minutes it exits (`PULSE_IDLE_EXIT` seconds to change). The
   launcher toggles it with SIGUSR1. SwiftBar's own webview popover would
   do the job too but paints a "SwiftBar: pulse-limits" title bar that
   cannot be turned off; if the helper is not built the script falls back
   to it automatically.
7. Activity comes from the transcripts Claude Code writes under
   `~/.claude/projects/*/*.jsonl`: output tokens of assistant lines stamped
   in the last minute, deduplicated by message id (a streaming reply is
   written several times), plus seconds since any transcript was touched.
   The helper measures it every 2 s while the panel is open and pushes it
   into the page; `pulse-popover --activity` prints one sample, which the
   plugin embeds as the initial value. About 30 ms per sample.
8. The plugin declares `runInBash=false`, so SwiftBar executes the script
   and the launcher directly. Its default is `zsh -l -c …`, which loads
   your login profile (nvm, brew shellenv) on every run and every click,
   about half a second here.

The token is never written anywhere. The only network traffic is that one GET.

Claude Code refreshes the token roughly hourly while it runs. If it has not
run for a while the token expires, the API answers 401, and the monitor turns
amber with `TOKEN EXPIRED`. Open Claude Code once and it heals. Refreshing
the token from here is deliberately not done: rotating it behind Claude
Code's back could log Claude Code out.

## Install

One line, with Homebrew (once the repo is public):

    brew install dnacenta/tap/pulse-limits && pulse-limits install

Or the installer script, which also installs jq and SwiftBar if missing:

    curl -fsSL https://raw.githubusercontent.com/dnacenta/pulse-limits/main/install.sh | bash

Either way you need macOS, Homebrew, the Xcode Command Line Tools (the two
helpers are compiled on your machine, ~10 s) and a Claude Code login in the
Keychain: run `claude` once. The installer is safe to re-run; it updates in
place. `./install.sh --uninstall` or `pulse-limits uninstall` removes it.

By hand:

    git clone https://github.com/dnacenta/pulse-limits.git
    cd pulse-limits && ./build.sh && ./pulse-limits install

## The `pulse-limits` command

    pulse-limits install       link the plugin into SwiftBar and start it
    pulse-limits uninstall     unlink it, drop cache and settings
    pulse-limits theme NAME    crt | modern | cyber | term | synth | analog
    pulse-limits refresh       force a live fetch now
    pulse-limits open          show or hide the monitor
    pulse-limits status        print the current reading as JSON

SwiftBar's own menu is hidden by the plugin metadata; manage it from the
terminal (`pkill SwiftBar`, `open -a SwiftBar`,
`open "swiftbar://refreshallplugins"`).

## Tuning

Top of `pulse-limits.5m.sh`: `MIN_INTERVAL`, `HISTORY_HOURS`, popover size.
Top of the script in `panel.html`: the palette `C`, the `tone` thresholds,
the BPM mapping in `bpmNow()` (40 idle, 60 + 60·log10(1 + tok/100) busy,
capped at 180), trace speed, and the ECG shape (a sum of five gaussians:
P, Q, R, S, T). Rename the script to change the cadence
(`pulse-limits.2m.sh`, etc.).

Force a live call: Option-click the header of the right-click menu, or run
`./pulse-limits.5m.sh --reset`.

## Preview without SwiftBar

    npx playwright screenshot --viewport-size=520,316 --wait-for-timeout=1500 \
      "file://$PWD/panel.html?theme=synth#$(printf '%s' '{"plan":"MAX 20X","source":"LIVE","status":"","hint":"","fetched":0,"history":[],"windows":[{"label":"SESSION","pct":63,"resets":null}],"credits":null,"activity":{"tok_per_min":1200,"idle_s":2,"sessions":1}}' | base64)" out.png

`attic/claude64.5m.sh` is the earlier Commodore 64 text-only version.
