# Go

Go is a macOS copilot that teaches by doing. Ask it how to do something and it
walks you through it one step at a time on your real screen: a blue cursor flies
to the next thing to click, highlights it, and a short bubble beside the cursor
says what to do. When you click, Go checks what happened and gives the next
step. If you click the wrong thing, it points you back. Or say "do it for me"
and Go performs the steps itself, checking each one as it goes.

Go lives in the menu bar. Hold **Control + Option**, speak, and release.

## What it does

- **Guided walkthroughs.** One step at a time, planned from what is actually on
  screen, never from a fixed script. Go waits as long as you need, notices
  when you finish a step, and corrects wrong turns.
- **Do it for me.** The same plan, carried out by Go: clicking, typing, pressing
  keys and opening apps, verifying each step before the next.
- **Pointing and answers.** "Where is…?" gets the cursor on the target, and a
  quick question gets a short spoken answer.
- **Keyboard work.** Go can type into whatever has focus (a spreadsheet cell,
  an editor, a terminal) and press keys and shortcuts, so tasks like adding a
  calculated column, filling it down and charting it can be done for you.
  Shortcuts that quit, lock, log out or empty the Trash are never pressed;
  ones that close or delete ask first.
- **Routines.** After Go helps with something, say "Save this as" and a
  name. Later, "Run <name>" does it for you and "Walk me through <name>"
  guides you. Steps are saved by what they target (a button's name, a menu
  path, a field label), not by screen position. Anything typed into
  password-like fields is never saved.
- **Trusted mode.** Optional. Go acts without confirmation cards, except for
  anything that deletes, pays or touches passwords, which always asks first.
- **Accessible output.** Everything Go says is also shown in full in the
  bubble.

## How it works

```
 push-to-talk ──▶ Gemini Live (speech in, tool calls)
                      │
                      ▼
              GoWalkthroughCoordinator ──▶ /go-plan (Gemini planner, via worker)
                      │                         ▲
     accessibility tree + screenshot ───────────┘
                      │
                      ▼
      HarnessServer ─▶ ActionSafetyKernel ─▶ act ─▶ ActionVerifier
                      │
                      ▼
      blue cursor + highlight + bubble        ElevenLabs speech (via worker)
```

1. **Sensing.** Go reads the accessibility tree that macOS apps publish for
   VoiceOver: named, positioned controls. When a control has no name (an
   icon-only button, a web canvas), the planner can ask for a screenshot and
   ground the target visually.
2. **Planning.** The Cloudflare worker's `/go-plan` route asks Gemini for the
   single next step, as structured JSON: a step, a question, an answer, a point,
   or "done".
3. **Acting safely.** Every action goes through a local harness. A deterministic
   safety kernel allows it, asks you on a confirmation card, or refuses it
   outright (for example emptying the Bin or anything involving a password
   field). An action only counts as done when a second read of the app shows
   that it happened.
4. **Speaking.** Gemini Live handles the conversation and tool calls, and
   ElevenLabs speaks each reply. API keys stay in the worker; the app never
   ships with them.

## Requirements

- macOS 14.2 or later, with Xcode
- Node.js, to run the worker
- A Gemini API key and an ElevenLabs API key

## Setup

1. **Signing.** Create `Signing.local.xcconfig` next to `Signing.xcconfig`
   with your own bundle identifier (this file is git-ignored):

   ```
   GO_BUNDLE_ID = com.yourname.go
   ```

   Then open `Go.xcodeproj` and choose your team under Signing & Capabilities.

2. **Keys.** Create `worker/.dev.vars` (git-ignored):

   ```dotenv
   GEMINI_API_KEY=
   ELEVENLABS_API_KEY=
   ```

   Then point the app at the local worker. This also generates the shared
   client key:

   ```bash
   python3 scripts/go-configure-local.py
   ```

3. **Worker.** Start it and leave it running:

   ```bash
   cd worker && npm ci && npm run dev -- --local --ip 127.0.0.1 --port 8787
   ```

4. **Run.** Build and run the `Go` scheme from Xcode (Cmd+R). Grant
   **Accessibility**, **Screen Recording** and **Microphone** when asked.

[`GO_SETUP.md`](GO_SETUP.md) has provider checks and step-by-step manual tests.

## Project layout

| Path | What it is |
|---|---|
| `Go/GoApp.swift`, `GoController.swift` | App entry point and app-wide state (permissions, onboarding, shortcut, overlay) |
| `Go/GoPanelView.swift`, `MenuBarPanelManager.swift` | The menu bar panel |
| `Go/OverlayWindow.swift`, `GoNotch.swift`, `GoGuidePresenter.swift` | The blue cursor, highlight, bubbles and notch status |
| `Go/GoWalkthrough*.swift`, `GoStepPlanner.swift`, `GoStepExecutor.swift` | Walkthroughs: planning the next step, detecting completion, doing it for you |
| `Go/GoScreenClick.swift`, `GoKeystrokes.swift`, `GoTextFields.swift`, `GoMenuPointer.swift` | Clicking, typing and menu pointing for controls the accessibility API cannot press |
| `Go/GoTrustedMode.swift`, `GoVoiceActionPolicy.swift`, `GoGuidanceIntent.swift` | What Go may do without asking, and what the owner's words authorise |
| `Go/GoGoalStore.swift`, `GoGoalTool.swift` | The remembered goal ("remember my goal…") |
| `Go/GoRoutine.swift` | Saved routines: what a step records, the store, the voice phrases, and finding a saved step on the current screen |
| `Go/Realtime*.swift`, `GoVoiceTransport.swift`, `ElevenLabsTTSClient.swift`, `GoSpeechBuffer.swift` | Voice: the Gemini Live session, its tools, and spoken replies |
| `Go/PushToTalkShortcut.swift`, `GlobalPushToTalkShortcutMonitor.swift` | The push-to-talk key |
| `Go/Accessibility*.swift`, `ElementActionIntent.swift` | Reading apps through the accessibility API |
| `Go/HarnessServer.swift`, `ActionSafetyKernel.swift`, `ActionVerifier.swift`, `EscalationLadder.swift` | The harness every action goes through: policy, execution and verification |
| `Go/HarnessConfirmations.swift`, `Confirmation*.swift`, `ApprovalRulesKeychainStore.swift`, `HarnessAppPolicy.swift` | Confirmation cards and "Always allow" rules (kept in the Keychain) |
| `worker/` | Cloudflare worker: `/go-plan`, `/gemini-live-token`, `/tts` |
| `GoTests/` | Unit tests (Swift Testing) |
| `scripts/` | Local setup, smoke checks and live harness tests |

## Tests

```bash
scripts/run-tests.sh                        # unit tests, driven through Xcode
node --test worker/tests/go-plan.test.mjs   # worker planner tests
python3 scripts/go-voice-smoke.py           # worker + providers (uses a little API credit)
python3 scripts/planner-tests.py            # live harness tasks; run Go with --harness
```

`run-tests.sh` drives Xcode's own test action because building with
`xcodebuild` into Xcode's DerivedData can invalidate the app's permission grants.

## Launch flags

| Flag | Effect |
|---|---|
| `--harness` | Opens the harness socket at `~/Library/Application Support/Go/harness.sock` for scripted testing |
| `--harness-dry-run` | Every harness request is a dry run |

Logs are written to `~/Library/Logs/Go`.

## Known limitations

- Go can only point at what it can find. Controls with neither an accessibility
  name nor a clear visual label may not be located.
- Verification confirms that the app reacted, not that the result was what you
  intended. Nothing undoes a click.
- Only the frontmost app is guided. Nothing has been tested on a second display.

## License

MIT, see [`LICENSE`](LICENSE). Go began as a fork of an MIT-licensed project;
the original copyright notice is kept in `LICENSE` as that license requires.

