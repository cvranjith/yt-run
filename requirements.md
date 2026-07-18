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

**Weighted consumption rate by mode**: the daily/binge *limits* themselves are unchanged (still 60/20 min by default), but how fast real time eats into them now depends on View vs. Listen vs. Car — foreground viewing always counts at 100%; background Listen and Car each have their own configurable rate (`listenRatePercent`/`carRatePercent` in Settings, default 50%/10%). E.g. at the defaults, 10 real minutes of background listening only uses 5 minutes of allowance, and 10 real minutes of car audio only uses 1. `UsageTracker.recordTick(weight:...)` accumulates the weighted (possibly fractional) seconds and only advances the integer counters once they cross a whole second, so low rates don't get rounded away to zero. `WatchSegment`/Daily History still records the *real* unweighted seconds watched — only the gate's counters are weighted.

---

# YouTube Playback

Embedded via `WKWebView` pointed at youtube.com, using a **persistent** (non-ephemeral) `WKWebsiteDataStore` so cookies/session survive app restarts.

Google account login is **not required**. Using YouTube as a guest is acceptable — YouTube's guest recommendations still adapt to watch history within the persisted session. Login remains a "nice to have," not a hard requirement.

Standard browser controls (Back, Forward, Reload) live in the YouTube screen's toolbar, backed directly by the WKWebView's own history (`canGoBack`/`canGoForward` mirrored via KVO). Reload exists specifically for when a video gets stuck (spinning/stalled) without needing to leave the screen and lose the ability to go forward again — the same fix as refreshing a stuck tab in a normal browser.

---

# Background Audio

Requirement: when the phone is locked or put in a pocket, audio from a video already playing must keep playing, with play/pause controllable from the Lock Screen / Control Center.

Implementation approach:
- Enable the "Audio, AirPlay, and Picture in Picture" Background Mode capability.
- Configure `AVAudioSession` category `.playback` so iOS treats the app as an audio app and keeps it alive in the background.
- Inject JavaScript into the WKWebView to prevent the YouTube page from auto-pausing on `visibilitychange`/`document.hidden` when backgrounded.
- Use `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` to surface lock-screen/Control Center play/pause controls, wired back to the WKWebView via JS bridge calls.

Note: this is the highest-risk/most-experimental part of the MVP — mobile web pages often fight background playback, so this may take a few iterations to get reliable on-device.

**Bug fix — audio surviving past the lock**: `evaluateJavaScript` calls made while backgrounded aren't guaranteed to run promptly (the WKWebView content process can be suspended for rendering/JS purposes even while its already-established audio output keeps playing), so a JS-only `pause()` could silently no-op right when the daily/binge limit was hit while the phone was locked — audio kept playing straight through the Locked screen. Fixed with `YouTubeWebViewStore.forceStopAudio()`, which deactivates the `AVAudioSession` (an OS-level stop, independent of WKWebView's own state) alongside the JS pause call, checked synchronously inside the same per-second timer tick that increments usage — not only via a separate `onChange(of: isLocked)`, whose SwiftUI-render-driven firing can lag while the app isn't on screen. `reactivateAudioSession()` re-enables playback once allowed again (e.g. after a run, or reopening the YouTube screen).

---

# Daily History

A "Daily History" screen (list of past days, tap into a detail view) shows what happened each day: total watched, and a breakdown by:

- **View vs. Listen vs. Car** — three-way split, reliable-to-best-effort. `scenePhase == .active` (foregrounded, screen on) = View. Backgrounded (locked/switched away, audio still playing) splits further into Listen vs. Car based on the current `AVAudioSession` output route: a real CarPlay connection is detected automatically (`.carAudio` port type); a plain Bluetooth car stereo (most cars — indistinguishable from any other Bluetooth accessory to iOS) requires the car's Bluetooth device name to be entered in Settings, matched as a case-insensitive substring. See `CarAudioDetector`.
- **Shorts vs. regular videos** — best-effort. Detected via URL pattern (`/shorts/` vs `/watch`). YouTube's Shorts feed scrolls between clips without always triggering a full page navigation, so a JS bridge (patched `history.pushState` + periodic polling) is used to catch those transitions, but rapid swiping may still undercount individual clips.
- **Channel name** — best-effort. Scraped from the page via a handful of known CSS selectors/microdata. Fragile: YouTube can change its markup at any time without notice, silently breaking this (falls back to "Unknown" rather than crashing). When extraction misses, `ChannelScrapeDebugLog` captures a snippet of the page's HTML around where the channel should be, capped at the last 30 misses in UserDefaults, and `CloudSyncService` pushes it to `fit/ytrun/debug/channel-misses.json` on every sync — a temporary remote-debugging aid so a real failure case can be inspected without HTML being manually relayed. Delete this mechanism once scraping is reliable.
- **Content category** (gaming/music/education/podcast/etc.) — explicitly NOT implemented. Not reliably obtainable without the paid YouTube Data API, which reopens the same cost problem as the rejected Strava integration.

Note: View/Listen/Car is purely a Daily History categorization — it does NOT change daily/binge limit enforcement. Car-mode listening still counts against the same limits as any other listening.

Implementation: `WatchSegment` (SwiftData) logs continuous stretches of consistent view/listen/car + Shorts/video + channel + video URL, closed and persisted whenever any of those change (see `WatchHistoryRecorder`). The Daily History UI aggregates these grouped by calendar day, alongside that day's `RunRecord` entries.

The per-day detail screen also lists individual videos watched that day (segments collapsed back into one row per video URL, with total watched time — not the video's full length, which YouTube doesn't expose without the paid Data API). Titles are resolved on-demand via the same oEmbed lookup used by Cloud Sync, cached back onto the segment once fetched. The "Videos" section is the last section on the day-detail screen.

Tapping a video opens a detail screen (`VideoDetailView`) showing its channel, type (Shorts/video), and a View/Listen/Car time breakdown for that specific video — with a separate "Watch Again" button to actually reopen it in the in-app YouTube view (still subject to the daily/binge gate, same as any other watch; there's no "escape" link that opens outside the app, consistent with the app's whole premise). Reopening loads the URL in the destination's `onAppear` rather than a tap gesture layered on the `NavigationLink` — the latter silently breaks navigation because the two gesture recognizers fight each other.

**Hiding a video**: either from a swipe action on the Videos list or a button on `VideoDetailView`, a video can be permanently redacted (`WatchSegment.hide(_:)`) — wipes `videoURL`/`videoTitle`/`channelName` on every segment belonging to it and sets `isHidden = true`, but leaves `durationSeconds`/view-listen-car/Shorts flags untouched, so daily totals and the Totals/Content-type sections stay accurate. Irreversible by design (no "undo" — the whole point is not keeping a record of what it was). All hidden segments across a day are merged into a single "Hidden video" row rather than shown separately, since redacted entries are intentionally indistinguishable from each other.

---

# Cloud Sync

Scope: only videos watched *through this app's gate* — not full cross-device YouTube history. (YouTube's Data API has no endpoint for a user's watch history at all, even with OAuth consent — this is a hard platform limitation, not a cost/quota one like Strava.)

Pushes local watch history to the same OCI Object Storage bucket used by the `screentime` and `we-gym-with-w` projects (same PAR), under `fit/ytrun/data/` — the PAR is scoped to only permit object names starting with `fit/`, confirmed against `we-gym-with-w`'s own `PFX = "fit/"` constant. One JSON file per day (`fit/ytrun/data/<date>.json`), full overwrite each time (not append), plus a maintained `index.json` listing which dates exist — same convention as `screentime/push_data.py`.

- **Implicit, foreground-triggered** — `CloudSyncService` is owned by `ContentView` and shared via `.environmentObject`, and `sync(modelContext:)` is fired silently from both `ContentView.onAppear` (app opened) and `YouTubeView.onAppear` (Watch YouTube tapped); a manual "Sync to Cloud" button remains on the Daily History screen too, sharing the same instance/state. Deliberately still not an OS-scheduled *background* sync — iOS background tasks don't run on a reliable clock — but "whenever the app is actually open" is reliable, and covers the two moments this app is normally opened for anyway.
- `sync()` no-ops if already in flight, so firing it from two `onAppear`s back-to-back (open app → tap Watch YouTube) is safe.
- Catch-up is automatic, not a separate feature: `daysNeedingSync` re-pushes every calendar day with activity on/after `lastSyncAt` (tracked in UserDefaults), so a day missed because the app wasn't opened gets picked up in full on the next sync, with no separate "pending" list to maintain.
- On sync: resolves any missing video titles via YouTube's public oEmbed endpoint (no API key/quota, and reliable — unlike the Shorts/channel-name JS scraping elsewhere), caches results locally so they're not re-fetched, then re-uploads every calendar day that has activity since the last successful sync (always a full day overwrite, so nothing needs per-segment sync-state tracking). Also pushes the channel-scrape debug log (see Daily History) as a best-effort side effect.
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
