# Setting up the "Summarize via ChatGPT" Shortcut

This is the server-free summarizer described in `requirement-ai-chatgpt.md`,
confirmed working end to end. It's a peer alternative to the regular
"Summarize" button (which uses ai-gateway) — this one hands a prompt +
transcript to your own ChatGPT iPhone app via a Shortcut you build
once, using YTRun's own App Intents ("Get Pending Transcript" / "Save
Summary") to pass data both ways and iOS's `x-callback-url` support to
return control to YTRun automatically.

App Intents rather than the clipboard: an earlier version of this used
"Get Clipboard"/"Copy to Clipboard", which worked but triggered two
unavoidable "Allow Paste" prompts per run (an iOS privacy control that
can't be suppressed or pre-authorized). Since Shortcuts passes values
between actions through its own execution engine — never the
pasteboard — calling this app's own actions instead means the
pasteboard is never touched at all, and neither prompt ever appears.

## Prerequisites

- The ChatGPT app installed, opened at least once, and signed in
  (Shortcuts only lists a third-party app's actions after iOS has seen
  it launch at least once).
- YTRun installed with this feature (its "Get Pending Transcript" and
  "Save Summary" actions need YTRun to have been built and launched at
  least once too, same reasoning).

## 1. Create the Shortcut

The Shortcut itself is deliberately generic — it doesn't contain the
actual summarization prompt at all. YTRun builds the full prompt +
transcript text and hands it over via "Get Pending Transcript"; the
Shortcut just asks ChatGPT with that, then hands the reply back via
"Save Summary".

1. Open the **Shortcuts** app.
2. Tap **+** (top-right) to create a new shortcut.
3. Tap the shortcut's title at the top and rename it to match YTRun's
   Settings → **ChatGPT Shortcut** field — default is **`YTRun
   Summarize`**. This must match **exactly** (case-sensitive).
4. Tap **Add Action**, search **"Get Pending Transcript"**, and add it
   — it should appear grouped under the YTRun app icon.
5. Tap **Add Action** again, search **"ChatGPT"**, and add **Ask
   ChatGPT** (exact name may vary slightly by ChatGPT app version).
   - Tap its **Message** field and insert the **Get Pending
     Transcript** output variable — no typed text in this field at
     all. The prompt is already part of what that action returns.
   - **Start new chat**: on (each run starts fresh, no leftover
     conversation context).
   - **Continuous chat**: off.
   - **Show When Run**: off (lets it run without the ChatGPT app
     coming to the foreground — confirmed working).
6. Tap **Add Action** again, search **"Save Summary"** (also under the
   YTRun app icon), and add it. Set its **Summary** parameter to the
   **Ask ChatGPT** action's response/output variable.
7. Tap **Done**. That's the complete Shortcut — 3 actions, nothing else.

## 2. Quick standalone test (before touching the app)

There isn't a clean way to test "Get Pending Transcript" standalone —
it only returns something real once YTRun has actually set it via the
"Send to ChatGPT" button (step 3 below). Skip straight to the full
round-trip test.

## 3. Test the full round trip from YTRun

1. Open a video with captions in YTRun.
2. Download menu → **Summarize via ChatGPT**.
3. Pick a length (Short/Paragraph/Detailed) and tap **Send to
   ChatGPT**.
4. iOS switches to the Shortcuts app briefly (you'll see it run, with
   ChatGPT working in the background), then switches back to YTRun
   automatically with the result — no system prompts should appear
   along the way.
5. If it doesn't return automatically, expand **Debug Info** at the
   bottom of that screen to see exactly what happened, and there's a
   **Check for Result** button next to the status line as a manual
   fallback (in case "Save Summary" ran but the automatic callback
   that was supposed to follow it didn't).

## Troubleshooting via the Debug Log

- **"You are logged out. Please open the ChatGPT app to log in."**
  (`errorCode=2014`) — "Ask ChatGPT" needs a "warm" login session; if
  this happens, open the ChatGPT app directly first, confirm it shows
  your account (not a login screen), then retry.
- **Reply just says "please paste the transcript" or asks for input**
  — the Message field in "Ask ChatGPT" isn't actually wired to "Get
  Pending Transcript"'s output. Fix step 5 above.
- **State stuck on "Waiting for the Shortcut to return…" indefinitely**
  — the Shortcut either never completed, or "Show When Run" ended up
  on and it's sitting in the ChatGPT app. Use **Check for Result** once
  you believe "Save Summary" has actually run.
- **"Returned from the Shortcut, but 'Save Summary' was never
  called…"** — the callback fired, but nothing was ever saved. Check
  that "Save Summary" is actually the Shortcut's last action and its
  Summary parameter is wired to Ask ChatGPT's output, not left blank
  or pointed at the wrong variable.
- Wrong shortcut name (mismatch with Settings) shows up as Shortcuts
  opening to its main list rather than running anything, with YTRun
  sitting on "Waiting for the Shortcut to return…" indefinitely since
  nothing was ever going to call back.
- If "Get Pending Transcript" or "Save Summary" don't show up at all
  in Shortcuts' action search: make sure YTRun has been launched at
  least once since it was last installed/rebuilt — App Intents are
  indexed from the installed binary and sometimes need that first
  launch (or occasionally a device restart) before Shortcuts picks
  them up.

## What this doesn't do (yet)

- Short/Paragraph/Detailed prompts live in `ChatGPTShortcutBridge.buildPayload`
  in the app (not the Shortcut) — matching ai-gateway's own prompts.
- No automatic save anywhere — the result is shown with a Share button,
  same as the regular Summarize screen.
- The existing **Summarize** button (ai-gateway) is completely
  unaffected by any of this.
