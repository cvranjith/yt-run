# YTRun — User Manual

YTRun gates YouTube behind a daily time allowance and a running
requirement: watch your allowance, then go for a run (or hit a
qualifying distance/duration) to earn more. It also has a full set of
YouTube quality-of-life features layered on top — Shorts blocking,
background Listen Mode, downloads, captions, and two independent ways
to get an AI summary of a video.

## Contents

1. [Home screen](#1-home-screen)
2. [Watching YouTube](#2-watching-youtube)
3. [Summarize (AI Gateway)](#3-summarize-ai-gateway)
4. [Summarize via ChatGPT — building the Shortcut](#4-summarize-via-chatgpt--building-the-shortcut)
5. [Downloads & Captions](#5-downloads--captions)
6. [Runs & rewards](#6-runs--rewards)
7. [History](#7-history)
8. [Settings reference](#8-settings-reference)

---

## 1. Home screen

- **Watch YouTube** — the gated YouTube browser (see §2).
- **Start a Run** — GPS-tracked run; completing one that qualifies
  (§6) grants extra viewing minutes.
- **View History** — daily watch time broken down by category (screen,
  background listen, car).
- **Run History** — past runs, distance/duration/estimated calories.
- **Downloads** — files saved from the YouTube screen (§5).
- **Settings** — all the toggles/fields in §8.

The stats card at the top shows remaining minutes for today and for
the current binge window — see §8 for what those mean.

## 2. Watching YouTube

The top control bar, left to right:

- **Home** — back to the app's Home screen.
- **◀ / Reload** — the web page's own back button, and a reload if a
  video gets stuck.
- **••• menu** — Forward, Open a Link (paste a YouTube URL or bare
  video ID), Debug Info.
- **Headphones icon** — toggles **Listen Mode**: forces lowest video
  quality and covers the player (audio keeps playing) — for when
  you're listening, not watching, and don't want the picture eating
  battery/data. Also changes the Download button to download audio
  only.
- **Download menu (⬇)** — the video's per-video actions:
  - **Download Video** / **Download Audio** (depending on Listen
    Mode) — saves to Downloads.
  - **View Captions** — see §5.
  - **Summarize** — AI Gateway–based summary, see §3.
  - **Summarize via ChatGPT** — Shortcut-based summary, see §4.

**View Captions** and both **Summarize** options are greyed out for
videos with no captions at all (checked automatically per video, the
same way YouTube's own apps detect it — no need to tap first and find
out).

**Fullscreen**: this app builds its own fullscreen (many devices don't
expose the web page's native fullscreen API) — tap the video, then the
fullscreen icon. Tap anywhere to bring transport controls back; there's
a dedicated exit button.

**Restrict Shorts** (Settings, off by default) hides Shorts thumbnails
everywhere and redirects away from direct Shorts links.

## 3. Summarize (AI Gateway)

Uses a self-hosted server (the separate `ai-gateway` project) running
Codex CLI to summarize the transcript. Requires Settings → **AI
Gateway** to be filled in (Gateway URL, Client ID, Client Secret — get
these from your ai-gateway's own `/ui` dashboard). Use **Test
Connection** there to confirm it's reachable.

To use it: Download menu → **Summarize** → pick a length (Short /
Paragraph / Detailed) → tap **Summarize**. Nothing is sent to the
server until you tap that button — picking a length alone doesn't fire
a request. Once fetched, tap the speaker icon to have it **read aloud
on-device** (fully local text-to-speech, pause/resume supported); it
pauses the video first so the two don't talk over each other.

Results are cached in memory per video+length for as long as the app
is open on that video — reopening the sheet or flipping back to an
already-fetched length shows it instantly with a **Regenerate**
button, with no server call. Moving to a different video and back
re-summarizes fresh (nothing is kept "forever").

## 4. Summarize via ChatGPT — building the Shortcut

This is a second, independent summarizer that needs **no server** —
it uses your own ChatGPT iPhone app via a Shortcut you build once. This
setup step is the fiddly part, so follow it exactly.

### Prerequisites

- The ChatGPT app installed, opened at least once, and **signed in**
  (Shortcuts only lists a third-party app's actions after iOS has seen
  it launch once).

### Build the Shortcut (one-time)

The Shortcut is deliberately dumb — it doesn't contain any prompt or
know anything about "short/paragraph/detailed." YTRun builds the full
prompt + video transcript and hands it over via its own "Get Pending
Transcript" action; the Shortcut asks ChatGPT with that, then hands
the reply back via YTRun's "Save Summary" action. No clipboard
involved — App Intents pass values through Shortcuts' own execution
engine, which is also why this doesn't trigger any "Allow Paste"
prompts (an earlier clipboard-based version did, unavoidably).

1. Open the **Shortcuts** app → **+** (top-right) → new shortcut.
2. Tap the shortcut's title at the top and rename it to **exactly**
   match Settings → **ChatGPT Shortcut** in YTRun — default is
   **`YTRun Summarize`** (case-sensitive, must match exactly).
3. **Add Action** → search **"Get Pending Transcript"** → add it (appears
   grouped under the YTRun app icon).
4. **Add Action** → search **"ChatGPT"** → add **Ask ChatGPT**.
   - Tap the **Message** field and insert the **Get Pending
     Transcript** output variable — do **not** type any prompt text
     here. Nothing but that one variable chip should be in this field.
   - **Start new chat**: **On**.
   - **Continuous chat**: **Off**.
   - **Show When Run**: **Off** (this is what lets it run without the
     ChatGPT app popping to the foreground — confirmed working).
5. **Add Action** → search **"Save Summary"** (also under YTRun) → add
   it. Set its **Summary** parameter to the **Ask ChatGPT** action's
   response/output variable.
6. Tap **Done**.

That's the whole Shortcut — exactly 3 actions: **Get Pending
Transcript → Ask ChatGPT (Message = that output) → Save Summary**.

### The mistake that's easy to make

- **Typing the prompt into "Ask ChatGPT" instead of inserting the "Get
  Pending Transcript" variable.** If Message contains any typed text,
  the transcript YTRun sends never reaches ChatGPT — you'll get a
  reply like "please paste the transcript." Message must be *only*
  that one variable chip.

### Test it

There's no clean standalone test for this version (unlike the old
clipboard-based one) — "Get Pending Transcript" only returns something
real once YTRun has actually set it via the button below, so test the
full round trip directly: open a video with captions → Download menu →
**Summarize via ChatGPT** → pick a length → **Send to ChatGPT**. iOS
switches to Shortcuts briefly, then back to YTRun automatically with
the result — no system prompts should appear along the way.

### Troubleshooting

Open **Summarize via ChatGPT** → expand **Debug Info** for a
timestamped log of exactly what happened. Common messages:

| Log message | What it means | Fix |
|---|---|---|
| "You are logged out. Please open the ChatGPT app to log in." | "Ask ChatGPT" needs a fresh/"warm" session | Open the ChatGPT app directly, confirm you're signed in, retry |
| Reply asks you to paste the transcript | Message field isn't wired to "Get Pending Transcript" | Fix "Ask ChatGPT" → Message (see mistake above) |
| Stuck on "Waiting for the Shortcut…" | Shortcut never finished, or "Show When Run" left it open in ChatGPT | Tap **Check for Result** once you believe "Save Summary" has run |
| "…'Save Summary' was never called…" | The callback fired but nothing was ever saved | Check "Save Summary" is the Shortcut's last action and its Summary parameter is wired to Ask ChatGPT's output |
| Shortcuts opens to its main list, nothing runs | Shortcut name doesn't match Settings | Fix the name in either place so they match exactly |
| "Get Pending Transcript"/"Save Summary" don't appear in Shortcuts' search | App Intents not yet indexed | Launch YTRun at least once after installing/rebuilding it, then check again |

Results here are cached the same way as AI Gateway's — per video +
length, cleared when you move to a different video.

## 5. Downloads & Captions

- **Download Video/Audio**: only works for videos YouTube serves
  without cipher-protected URLs — not every video will have this
  available; the app tells you plainly when it can't.
- **View Captions**: shows the transcript as readable text (or SRT),
  with adjustable font size, Share, and Save to Downloads.
- **Downloads** (Home screen): lists everything saved — tap a file to
  view it, swipe or use the trash icon to delete.

## 6. Runs & rewards

- **Start a Run** tracks GPS distance/duration live.
- A run **qualifies** if it meets *either* the minimum distance or
  minimum duration (Settings) — not both.
- A qualifying run either **ends an active cooldown early** (if you're
  in one) or **adds viewing minutes** — never both from the same run.
- **Simulate Run** (Locked screen) is a one-tap way to grant the
  reward without actually running, for testing. It only appears if you
  turn it on in Settings, and **turns itself back off after one use**
  — deliberate friction so it can't just sit there as a standing
  bypass.

## 7. History

- **View History**: per-day breakdown of watch time — foreground
  (screen), background listening, and car listening are each weighted
  differently toward your allowance (see §8).
- **Run History**: every past run with distance, duration, and an
  estimated calorie count (distance × weight — not medically precise,
  no heart rate involved).

## 8. Settings reference

| Section | Controls |
|---|---|
| Daily allowance | Total YouTube minutes per day (resets at midnight) |
| Binge protection | Binge limit, cooldown length, and how long a break has to be to forgive a partial binge |
| Run reward | Minutes granted per qualifying run |
| Qualifying run | Minimum distance **or** duration to count |
| Calorie estimate | Your weight, for the rough calorie estimate on runs |
| Background listening rate | How much of a real second of background/car listening counts against your allowance vs. watching with the screen on (always 100%) |
| Car Bluetooth device | Name your car's Bluetooth stereo so its listening time is tracked separately from generic headphones |
| Restrict Shorts | Hide Shorts everywhere in the YouTube screen |
| Show Simulate Run Button | See §6 — auto-disables after one use |
| AI Gateway | Gateway URL / Client ID / Client Secret + Test Connection — powers §3 |
| ChatGPT Shortcut | The exact Shortcut name to launch — powers §4 |
| Developer debug options | Reset today's usage; artificially add usage, for testing the Locked screen |

---

For the original design notes behind the ChatGPT-based summarizer
(what was tried, what turned out to be unreliable, what was confirmed
working), see `requirement-ai-chatgpt.md` and `chatgpt-shortcut-setup.md`
in this repo.
