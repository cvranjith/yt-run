# Setting up the "Summarize via ChatGPT" Shortcut

This is the server-free summarizer described in `requirement-ai-chatgpt.md`,
confirmed working end to end. It's a peer alternative to the regular
"Summarize" button (which uses ai-gateway) — this one hands a prompt +
transcript to your own ChatGPT iPhone app via a Shortcut you build
once, using the clipboard to pass data both ways and iOS's
`x-callback-url` support to return control to YTRun automatically.

## Prerequisites

- The ChatGPT app installed, opened at least once, and signed in
  (Shortcuts only lists a third-party app's actions after iOS has seen
  it launch at least once).
- YTRun installed with this feature.

## 1. Create the Shortcut

The Shortcut itself is deliberately generic — it doesn't contain the
actual summarization prompt at all. YTRun builds the full prompt +
transcript text and puts it on the clipboard before opening the
Shortcut; the Shortcut just reads the clipboard, asks ChatGPT, and
copies the reply back.

1. Open the **Shortcuts** app.
2. Tap **+** (top-right) to create a new shortcut.
3. Tap the shortcut's title at the top and rename it to match YTRun's
   Settings → **ChatGPT Shortcut** field — default is **`YTRun
   Summarize`**. This must match **exactly** (case-sensitive).
4. Tap **Add Action**, search **"Get Clipboard"**, and add it.
5. Tap **Add Action** again, search **"ChatGPT"**, and add **Ask
   ChatGPT** (exact name may vary slightly by ChatGPT app version).
   - Tap its **Message** field and insert the **Clipboard** variable
     (the output of the "Get Clipboard" action above) — no typed text
     in this field at all. The prompt is already part of what's on the
     clipboard by the time this runs.
   - **Start new chat**: on (each run starts fresh, no leftover
     conversation context).
   - **Continuous chat**: off.
   - **Show When Run**: off (lets it run without the ChatGPT app
     coming to the foreground — confirmed working).
6. Tap **Add Action** again, search **"Copy to Clipboard"**, and add
   it. Set its content to the **Ask ChatGPT** action's response/output
   variable (not the earlier Clipboard variable).
7. Tap **Done**. That's the complete Shortcut — 3 actions, nothing else.

## 2. Quick standalone test (before touching the app)

1. Copy a short paragraph of plain text somewhere (Notes works fine).
2. Open the **Shortcuts** app and tap your shortcut directly (not via
   YTRun) to run it once manually.
3. Expect two "Allow Paste" prompts along the way (the Shortcut reading
   your clipboard, then whatever reads the reply back) — that's an iOS
   privacy control, not something to fix.
4. Paste somewhere afterward to confirm you got a real reply back, not
   your original text.

## 3. Test the full round trip from YTRun

1. Open a video with captions in YTRun.
2. Download menu → **Summarize via ChatGPT**.
3. Pick a length (Short/Paragraph/Detailed) and tap **Send to
   ChatGPT**.
4. iOS switches to the Shortcuts app briefly (you'll see it run, with
   ChatGPT working in the background), then switches back to YTRun
   automatically with the result — two "Allow Paste" prompts appear
   along the way, same as the standalone test.
5. If it doesn't return automatically, expand **Debug Info** at the
   bottom of that screen to see exactly what happened, and there's a
   **Paste From Clipboard Instead** button next to the status line as
   a manual fallback.

## Troubleshooting via the Debug Log

- **"You are logged out. Please open the ChatGPT app to log in."**
  (`errorCode=2014`) — "Ask ChatGPT" needs a "warm" login session; if
  this happens, open the ChatGPT app directly first, confirm it shows
  your account (not a login screen), then retry.
- **Reply just says "please paste the transcript" or asks for input**
  — the Message field in "Ask ChatGPT" isn't actually wired to the
  Clipboard variable (e.g. it's still using "Shortcut Input", which is
  only populated when something explicitly passes input — running the
  Shortcut by tapping it directly does **not** count, only YTRun's
  `input=clipboard` URL does). Fix step 5 above.
- **State stuck on "Waiting for the Shortcut to return…" indefinitely**
  — the Shortcut either never completed, or "Show When Run" ended up
  on and it's sitting in the ChatGPT app. Use **Paste From Clipboard
  Instead** once you've manually gotten the reply onto the clipboard.
- **"Clipboard still has the original transcript…"** — nothing new was
  copied. Check step 6 (Copy to Clipboard must use the Ask ChatGPT
  response, not the earlier Clipboard variable).
- Wrong shortcut name (mismatch with Settings) shows up as Shortcuts
  opening to its main list rather than running anything, with YTRun
  sitting on "Waiting for the Shortcut to return…" indefinitely since
  nothing was ever going to call back.

## What this doesn't do (yet)

- Short/Paragraph/Detailed prompts live in `ChatGPTShortcutBridge.buildPayload`
  in the app (not the Shortcut) — matching ai-gateway's own prompts.
- No automatic save anywhere — the result is shown with a Share button,
  same as the regular Summarize screen.
- The existing **Summarize** button (ai-gateway) is completely
  unaffected by any of this.
