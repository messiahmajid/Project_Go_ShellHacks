# Go 👉

A tiny helper that lives in your Mac's menu bar and shows you how to do stuff by actually pointing at it.

We made this at ShellHacks.

## Why this exists

You know that moment. You're at your internship, your manager asks you to "just pull the numbers into a pivot table real quick," and your brain goes: *oh no, what do I do?*

Right now the fix goes something like this: screenshot the screen, paste it into a chatbot, read a giant list of steps, flip back to the app, forget step 3, flip back to the chat, repeat. Or you hand the whole thing to an AI that takes over your screen, and you still have no idea how to do it next time.

We wanted something in between. What if the help just showed up *on your screen*? You ask out loud, a little cursor flies over to the thing you need to click, highlights it, and waits while you do it. Then it shows you the next step. You actually learn it, because you did it. Kind of like a patient friend sitting next to you, except the friend doesn't sigh.

And this isn't just a "for us" thing. It's for anyone who's ever been lost in a settings menu (so, everyone): the new intern, the parent who calls you for every tech question, or you, the first time you open some app you've never used. Lots of people learn way better by being shown than by reading instructions.

## What it does

Hold **Control + Option**, say what you want, let go.

- **"How do I make a pivot table?"** The cursor flies to the right spot, highlights it, and walks you through one step at a time. It notices when you click and moves on. Click the wrong thing and it'll nudge you back.
- **"Turn on Do Not Disturb."** Say it like a request instead of a question and Go just does it for you, checking that each step actually worked.
- **"Save this as Weekly report."** Once you've done something, Go can remember it. Next week, "Run Weekly report" does it again, or "Walk me through Weekly report" shows you again.

Go talks to you, because honestly, who doesn't like a nice voice calmly showing them the way? But everything it says also shows up as text in a little bubble next to the cursor. So if you're hard of hearing, in a quiet library, or just have your sound off, you don't miss anything.

That's pretty much it. No big app window, no chat box. It hangs out in the menu bar until you need it.

## "Wait, it clicks things for me? Is that safe?"

Fair question, we asked ourselves the same thing. A few rules we built in:

- It never types into password fields, and it never saves anything that looks like a password or code.
- It asks you first before anything that deletes, closes or sends stuff.
- Some things it just won't do, like emptying your Trash or buying things. That's on you.
- It only counts a step as done once it can see the app really changed. No pretending.

## How it works (the short version)

Go reads your screen the same way screen readers do (macOS accessibility), so it knows most buttons by name. When something doesn't have a name, like an icon-only button, it looks at a screenshot instead.

Google's Gemini figures out **one next step at a time** based on what's actually on your screen right now. There are no pre-written scripts for specific apps, so it works (mostly) wherever you are. Gemini Live handles listening, and ElevenLabs gives Go its voice. The API keys sit in a small Cloudflare worker so they never end up inside the app.

## Running it yourself

You'll need a Mac (macOS 14.2+), Xcode, Node.js, and API keys for Gemini and ElevenLabs.

1. **Set a bundle id.** Make a file called `Signing.local.xcconfig` next to `Signing.xcconfig` with:
   ```
   GO_BUNDLE_ID = com.yourname.go
   ```
   Then open `Go.xcodeproj` and pick your team under Signing & Capabilities.

2. **Add your keys.** Make `worker/.dev.vars`:
   ```
   GEMINI_API_KEY=
   ELEVENLABS_API_KEY=
   ```
   Then run `python3 scripts/go-configure-local.py` so the app knows where your worker is.

3. **Start the worker** and leave it running:
   ```bash
   cd worker && npm ci && npm run dev -- --local --ip 127.0.0.1 --port 8787
   ```

4. **Run Go** from Xcode with ⌘R. macOS will ask for Accessibility, Screen Recording and Microphone permission. Say yes to all three.

Now hold Control + Option and ask it something. If things act weird, [`GO_SETUP.md`](GO_SETUP.md) has some checks.

## Stuff that's still rough

It's a hackathon project, so here's what we know about:

- English only for now.
- Simple things (settings, menus, opening apps) work well. Big multi-step jobs, like "analyze this spreadsheet and make a chart," work sometimes. Other times Go gets stuck and asks you for help.
- If there's a row of identical-looking unlabeled icons, it can occasionally point at the neighbour.
- We've only tested it on our own laptops, with one screen.

## If we kept going

- More languages, and a slower, calmer voice option.
- Sharing routines with friends, family or your team. Set up "Submit my timesheet" or "Video call the grandkids" once and just hand it over.
- A "what did I just do?" button that gives you a simple recap.

## Poking around the code

The app is Swift/SwiftUI in `Go/`, tests live in `GoTests/`, and the Cloudflare worker is in `worker/`. Good places to start:

- `GoWalkthroughCoordinator.swift` plans and follows the steps
- `GoGuidePresenter.swift` draws the cursor, highlight and speech bubble
- `ActionSafetyKernel.swift` decides what Go can do, what it asks about, and what it refuses
- `GoRoutine.swift` saves and replays routines

Tests: `scripts/run-tests.sh`.

## Credits

Go started from an open-source, MIT-licensed on-screen assistant, and we're grateful it existed. The original copyright notice lives in [`LICENSE`](LICENSE).
