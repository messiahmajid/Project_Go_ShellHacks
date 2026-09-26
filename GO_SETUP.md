# Go local voice setup

Go uses Gemini Live for speech input, reasoning, and tool calls. Go's accessibility harness resolves, checks, performs, and verifies actions. ElevenLabs speaks complete sentences as the reply arrives. If ElevenLabs fails (no credits, a rejected key, no network), the built-in macOS voice speaks the same words instead.

Each short ElevenLabs audio segment is buffered before playback. Go starts a completed sentence while Gemini continues its reply; it does not yet stream the audio bytes within a sentence. Gemini still generates audio as part of the existing Live protocol, but Go does not play that audio.

## Configure

1. Create `worker/.dev.vars` with these two entries and fill in the values locally:

   ```dotenv
   GEMINI_API_KEY=
   ELEVENLABS_API_KEY=
   ```

2. From the repository root, run:

   ```sh
   python3 scripts/go-configure-local.py
   ```

   This preserves existing app preferences, sets the worker address to `http://127.0.0.1:8787`, and generates a local client key if one is missing. It also selects the built-in ElevenLabs River voice if no local voice ID is set (library voices need a paid ElevenLabs plan).

3. Install the existing worker dependencies and start it:

   ```sh
   cd worker
   npm ci --no-audit --no-fund
   WRANGLER_SEND_METRICS=false npm run dev -- --local --ip 127.0.0.1 --port 8787
   ```

   Keep this process running while using Go. Restart it after changing `.dev.vars`. This is a local development server, not a public deployment.

   Run the worker from **this** checkout. Only one worker can use port 8787, and the app talks to whichever one holds it. A worker left running from another copy of the project silently serves its older planner. Check with `ps -axo command | grep wrangler`.

4. Open `Go.xcodeproj` and run the `Go` scheme. The menu panel shows `Gemini + ElevenLabs`. Hold Control + Option, speak, then release.

The key file and worker runtime directory are excluded from Git. API keys stay in the worker. The app receives a short-lived Gemini token and keeps the local client key in its existing preferences configuration.

## Check the providers

From the repository root, while the worker is running:

```sh
python3 scripts/go-voice-smoke.py
```

This checks that an unauthenticated request is refused, generates the fixed phrase `Go voice connection test.` through ElevenLabs, and requests a Gemini session token. It uses a small amount of API credit. It prints no credentials or tokens. The audio and result are saved to `/private/tmp/go-voice-smoke.mp3` and `/private/tmp/go-voice-smoke.json`.

This check does not prove microphone capture or the full app turn. Validate those in the running app. Actual ElevenLabs playback timing is logged as `spokenAudioStartedMs` in `~/Library/Logs/Go/voice-live.log`; Gemini's `firstAudioMs` records generated audio that is not played.

## Goal state check

Use separate push-to-talk turns:

1. “Remember my goal: make this Word document portrait.”
2. “What is my goal?”
3. “Actually, change my goal to landscape.”
4. “What is my goal now?”

Go should recall portrait, then landscape. These requests store intent; they do not change the Word document. The small local record is at `~/Library/Application Support/Go/goal.json`, with owner-only access. Restarting Go should preserve it. “My goal is complete” makes it inactive. “Forget my goal” clears it.

## Dynamic walkthrough check

There are no fixed workflows or fixed demo apps. From the app you want help with, say “Walk me through [your task].” The planner selects one next step from the actual goal and interface. A task that cannot be verified from the available controls must produce a question or limitation. Do not treat this as tested support for every app.

Go shows and speaks one instruction, then points when a unique, visible target can be resolved. Follow it and leave the app in front. After verification, Go automatically plans and presents the next instruction or a short question; you do not need to say “next.” The current step does not expire while you pause. Say “Stop the walkthrough” to stop observation. Changing or clearing the goal invalidates the old walkthrough. Control + Option interrupts speech and pointing.

Guidance requests stay read-only. Goal storage is silent during guidance. When control names aren't enough (sparse or very large interfaces, icon-only controls, or right after something opened a menu or panel), the planner also receives a screenshot of the display, sent to the configured Gemini service. Nothing is captured while a password field has focus. Incomplete AX reads, unsupported expected states, and unresolved controls still produce a question or limitation.

Worker validation:

```sh
node --test worker/tests/go-plan.test.mjs
node scripts/go-planner-smoke.mjs
```

The smoke check sends two synthetic control lists and goals to Gemini; it uses a small amount of API credit. It does not operate a real app. The planner follows Gemini's [structured output API](https://ai.google.dev/gemini-api/docs/generate-content/structured-output?hl=en).
