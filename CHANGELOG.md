# Changelog

## Unreleased

### Guidance
- Guided walkthroughs: one step at a time, planned from what is on screen. The
  cursor flies to the target, highlights it and shows the instruction in a
  bubble; Go notices when the step is done and moves on.
- Wrong clicks are noticed and Go points back to the right place.
- "Do it for me": Go performs the same steps itself (clicking, typing, keys,
  opening apps) and verifies each one.
- Pointing ("where is…") and short spoken answers to quick questions.
- Visual grounding for controls without accessibility names, such as icon-only
  buttons and web content.
- A remembered goal ("remember my goal…") that persists between launches.
- Routines: "Save this as <name>" keeps the steps of the walkthrough just
  finished; "Run <name>" replays them for you and "Walk me through <name>"
  guides you. Saved steps are found again by name, fall back to the planner
  when the screen differs, and never store secrets.
- Menu-bar icons and Dock items are targeted by name with exact positions.

- Statements and commands are carried out; explicit requests ("how do I",
  "walk me through", "show me how", "teach me") are guided.
- Keyboard steps: typing into what has focus and pressing keys/shortcuts, for
  spreadsheets, editors and keyboard-driven apps.

### Safety
- Every action goes through a local safety kernel: allowed, confirmed on a card,
  or refused (for example emptying the Trash or typing into password fields).
- An action counts as done only when a second read of the app shows it happened.
- Optional trusted mode: no confirmation cards except for deleting and
  passwords; paying, erasing and emptying the Trash are always refused.

### Voice
- Push-to-talk (Control + Option) with Gemini Live; replies spoken by ElevenLabs.
- All spoken text is also shown in full on screen.
- If ElevenLabs is unavailable, the built-in macOS voice speaks instead.
- Shortcuts are spoken as words, and formulas or links are referred to rather
  than read out.

### Long tasks
- Each finished step is checked against the screen before any praise; a step
  that didn't take is called out and repeated, not praised.
- For multi-part tasks the planner keeps a private checklist and short notes of
  what it saw on earlier screens, so later steps can use them.
- Routines can be listed, run, walked through, deleted, or all deleted (after a
  spoken yes), in your own words.

### Panel
- A menu bar panel in the style of Control Center: frosted glass, rounded
  cards and switches for trusted mode and showing the cursor.

### Project
- API keys live only in the Cloudflare worker (`/go-plan`, `/gemini-live-token`,
  `/tts`); the app never ships with them.
