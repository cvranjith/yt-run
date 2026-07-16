# Project: YouTube Running Gate (iOS)

## Goal

This is a personal hobby project intended primarily to learn SwiftUI and iOS development.

The app will NOT be published to the App Store initially. It will be installed on my own iPhone using Xcode (free Apple Personal Team).

The objective is NOT to create an unbreakable blocker. It is a self-discipline tool.

---

# High Level Concept

I intentionally watch YouTube only through this app.

The app tracks how much YouTube I have watched today.

When today's allowance is exhausted, the app no longer allows YouTube playback.

Instead, it displays a lock screen.

To unlock additional viewing time, I must complete a qualifying run, detected via a **self-built GPS tracker using CoreLocation** (see "Real Run Detection" below) — not a third-party service.

I fully understand I could bypass the app by opening Safari or the YouTube app. That is acceptable.

### Rejected approaches (for context)

- **Nike Run Club**: no public API — not viable.
- **Strava API**: has a public API, but as of mid-2026 Strava requires an active paid Strava subscription ($11.99/month) for Standard-tier API access. Rejected due to ongoing cost.
- **Apple HealthKit**: architecturally the cleanest (works with any run-tracking app that syncs to Apple Health), but requires a paid Apple Developer Program membership ($99/year) — this app uses free Personal Team signing. Rejected for now; could revisit if the account is ever upgraded.

---

# MVP Scope

Version 1 should contain only:

- SwiftUI application
- Embedded YouTube player
- Daily usage timer
- Daily allowance
- Lock screen
- Local persistence
- Settings page

Do NOT implement HealthKit yet.

Initially there should simply be a button:

"Simulate Run"

which grants additional viewing time.

---

# Tech Stack

- SwiftUI
- WKWebView
- JavaScript bridge if necessary
- UserDefaults (or another simple local persistence mechanism)
- MVVM architecture where appropriate

Avoid unnecessary third-party libraries.

---

# Initial Screens

## Home

Shows:

Today's allowance

Example:

Remaining:
18 minutes

Buttons:

Watch YouTube

Settings

---

## YouTube Screen

Contains embedded YouTube player.

Track playback time only while video is actually playing.

Pause counting when paused.

Return to Home anytime.

---

## Locked Screen

When allowance reaches zero:

"You've used today's YouTube allowance."

Button:

Simulate Run (+20 min)

After simulation:

Unlock immediately.

---

## Settings

Configurable:

Daily allowance (minutes) — default **60**

Binge limit (minutes) — default **20**
(cumulative minutes watched — pauses don't reset it — before a forced cooldown kicks in, independent of the daily total)

Cooldown (minutes) — default **40** (double the binge limit, but its own independent setting)
(once the binge limit is hit, YouTube is locked until this timer fully elapses OR a run is completed, whichever comes first)

Minutes earned per run

Reset today's usage

Developer debug options

All settings persisted locally (UserDefaults).

---

# Timer Rules

Track accumulated playback time.

Only count while YouTube is actually playing (including while playing in the background, e.g. phone locked — see Background Audio below).

Persist usage.

Reset automatically every new day.

Enforce two independent caps:
1. Daily cumulative minutes vs. daily allowance.
2. Binge limit + cooldown: hitting the binge limit (cumulative minutes, pauses don't reset it) immediately locks YouTube for the cooldown duration. Example: binge limit 20 min, cooldown 40 min — start watching at 10:00, hit the limit at 10:20, locked until 11:00 *if you don't run*. A run (real or simulated) either ends an active cooldown early OR extends the daily allowance — never both from the same run. If you're in a cooldown when the run completes, it just ends the cooldown (no extra daily minutes); otherwise it tops up the daily allowance as usual.
3. Binge inactivity reset (`bingeResetAfterMinutes`, default 30 min, independent of the cooldown duration): a *partial* binge session (cumulative watch time below the binge limit, so no cooldown was ever triggered) resets to 0 on its own after this many minutes without any watching. Without this, a partial session would otherwise sit there indefinitely — only fully hitting the limit (→ cooldown → reset), a run, or midnight ever cleared it.

---

# YouTube Playback

Embedded via `WKWebView` pointed at youtube.com, using a **persistent** (non-ephemeral) `WKWebsiteDataStore` so cookies/session survive app restarts.

Google account login is **not required**. Using YouTube as a guest is acceptable — YouTube's guest recommendations still adapt to watch history within the persisted session. Login remains a "nice to have," not a hard requirement.

---

# Background Audio

Requirement: when the phone is locked or put in a pocket, audio from a video already playing must keep playing, with play/pause controllable from the Lock Screen / Control Center.

Implementation approach:
- Enable the "Audio, AirPlay, and Picture in Picture" Background Mode capability.
- Configure `AVAudioSession` category `.playback` so iOS treats the app as an audio app and keeps it alive in the background.
- Inject JavaScript into the WKWebView to prevent the YouTube page from auto-pausing on `visibilitychange`/`document.hidden` when backgrounded.
- Use `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` to surface lock-screen/Control Center play/pause controls, wired back to the WKWebView via JS bridge calls.

Note: this is the highest-risk/most-experimental part of the MVP — mobile web pages often fight background playback, so this may take a few iterations to get reliable on-device.

---

# Daily History

A "Daily History" screen (list of past days, tap into a detail view) shows what happened each day: total watched, and a breakdown by:

- **View vs. Listen vs. Car** — three-way split, reliable-to-best-effort. `scenePhase == .active` (foregrounded, screen on) = View. Backgrounded (locked/switched away, audio still playing) splits further into Listen vs. Car based on the current `AVAudioSession` output route: a real CarPlay connection is detected automatically (`.carAudio` port type); a plain Bluetooth car stereo (most cars — indistinguishable from any other Bluetooth accessory to iOS) requires the car's Bluetooth device name to be entered in Settings, matched as a case-insensitive substring. See `CarAudioDetector`.
- **Shorts vs. regular videos** — best-effort. Detected via URL pattern (`/shorts/` vs `/watch`). YouTube's Shorts feed scrolls between clips without always triggering a full page navigation, so a JS bridge (patched `history.pushState` + periodic polling) is used to catch those transitions, but rapid swiping may still undercount individual clips.
- **Channel name** — best-effort. Scraped from the page via a handful of known CSS selectors. Fragile: YouTube can change its markup at any time without notice, silently breaking this (falls back to "Unknown" rather than crashing).
- **Content category** (gaming/music/education/podcast/etc.) — explicitly NOT implemented. Not reliably obtainable without the paid YouTube Data API, which reopens the same cost problem as the rejected Strava integration.

Note: View/Listen/Car is purely a Daily History categorization — it does NOT change daily/binge limit enforcement. Car-mode listening still counts against the same limits as any other listening.

Implementation: `WatchSegment` (SwiftData) logs continuous stretches of consistent view/listen/car + Shorts/video + channel + video URL, closed and persisted whenever any of those change (see `WatchHistoryRecorder`). The Daily History UI aggregates these grouped by calendar day, alongside that day's `RunRecord` entries.

---

# Cloud Sync (manual)

Scope: only videos watched *through this app's gate* — not full cross-device YouTube history. (YouTube's Data API has no endpoint for a user's watch history at all, even with OAuth consent — this is a hard platform limitation, not a cost/quota one like Strava.)

A "Sync to Cloud" button (Daily History screen) pushes local watch history to the same OCI Object Storage bucket used by the `screentime` and `we-gym-with-w` projects (same PAR), under `fit/ytrun/data/` — the PAR is scoped to only permit object names starting with `fit/`, confirmed against `we-gym-with-w`'s own `PFX = "fit/"` constant. One JSON file per day (`fit/ytrun/data/<date>.json`), full overwrite each time (not append), plus a maintained `index.json` listing which dates exist — same convention as `screentime/push_data.py`.

- Manual only — no scheduled/background sync. iOS background tasks don't run on a reliable clock, so a button is simpler and more predictable than approximating "every hour."
- On sync: resolves any missing video titles via YouTube's public oEmbed endpoint (no API key/quota, and reliable — unlike the Shorts/channel-name JS scraping elsewhere), caches results locally so they're not re-fetched, then re-uploads every calendar day that has activity since the last successful sync (always a full day overwrite, so nothing needs per-segment sync-state tracking).
- Analytics/AI processing deliberately happens OUTSIDE this app, in a separate Python batch project on the user's Mac — reading from the same OCI bucket, running on its own schedule. Keeps API keys/prompts out of the shipped app and iterable without a rebuild. Reading the analysis result back into an in-app dashboard, and any "knowledge base candidate" flagging, are explicitly deferred until that batch pipeline actually produces something.

---

# Real Run Detection

Implemented via `CoreLocation` — a "Start Run" flow built directly into this app tracks distance and elapsed time via GPS while a run is in progress (works with the phone locked, via background location updates, similar to the background-audio approach).

A run qualifies if it meets **either** threshold (configurable in Settings, not both required):
- Minimum distance (default 5K), OR
- Minimum duration (default 30 min)

Qualifying grants a flat `Minutes per run` reward (same setting used by "Simulate Run" today) — not scaled by distance/duration.

"Simulate Run" stays in place alongside real run detection (useful for testing); no plan to remove it currently.

---

# Future Versions (Do NOT implement now)

HealthKit integration — revisit only if the Apple Developer account is ever upgraded to a paid membership.

---

# Coding Preferences

Prefer:

- modern Swift
- SwiftUI
- readable code
- small reusable components
- comments explaining iOS concepts (I'm learning)

Avoid overengineering.

If there are multiple approaches, explain why one is preferred.

I prefer understanding over cleverness.

---

# Development Style

Please guide me incrementally.

Don't generate the entire application at once.

Instead:

1. explain architecture
2. create project structure
3. build one screen at a time
4. test frequently
5. explain important SwiftUI concepts along the way

Assume I am experienced in software architecture and backend development, but completely new to SwiftUI and Xcode.
