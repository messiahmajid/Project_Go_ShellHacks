#!/bin/zsh
# Run the unit tests through Xcode's own test action (like pressing Cmd+U).
#
# Building with xcodebuild into Xcode's DerivedData can invalidate the app's
# Screen Recording, Accessibility and Microphone grants, so this asks Xcode
# instead and waits for a new .xcresult bundle to appear.
set -e

PROJECT_DIRECTORY="${0:A:h:h}"
TEST_LOG_DIRECTORY=$(ls -d ~/Library/Developer/Xcode/DerivedData/Go-*/Logs/Test 2>/dev/null | head -1)

if [[ -z "$TEST_LOG_DIRECTORY" ]]; then
  echo "no DerivedData for Go — build once in Xcode first" >&2
  exit 1
fi

bundleBefore=$(ls -dt "$TEST_LOG_DIRECTORY"/*.xcresult 2>/dev/null | head -1)

osascript -e "tell application \"Xcode\"
  open \"$PROJECT_DIRECTORY/Go.xcodeproj\"
  set d to workspace document \"Go.xcodeproj\"
  repeat until (loaded of d) is true
    delay 1
  end repeat
  test d
end tell" >/dev/null 2>&1 &

for _ in {1..180}; do
  sleep 2
  bundleNow=$(ls -dt "$TEST_LOG_DIRECTORY"/*.xcresult 2>/dev/null | head -1)
  [[ "$bundleNow" == "$bundleBefore" || -z "$bundleNow" ]] && continue
  summary=$(xcrun xcresulttool get test-results summary --path "$bundleNow" 2>/dev/null) || continue
  # A build failure is a finished bundle with zero tests: print its errors.
  build=$(xcrun xcresulttool get build-results --path "$bundleNow" 2>/dev/null)
  # printf, not echo: echo would mangle escapes inside the JSON.
  printf '%s' "$summary" | BUILD_JSON="$build" python3 -c "
import sys, json, os
d = json.load(sys.stdin)
if not d.get('result'): raise SystemExit(1)
if d['totalTestCount'] == 0:
    try: b = json.loads(os.environ.get('BUILD_JSON') or '{}')
    except Exception: b = {}
    print(f\"BUILD FAILED: {b.get('errorCount', '?')} errors, 0 tests ran\")
    for e in (b.get('errors') or [])[:20]: print('  ERROR', e.get('message'), '|', (e.get('sourceURL') or '').split('/')[-1][:120])
    raise SystemExit(1)
print(f\"{d['result']}: {d['passedTests']} passed, {d['failedTests']} failed, {d['skippedTests']} skipped\")
for failure in d.get('testFailures', []):
    print('  FAIL', failure.get('testName'), '-', failure.get('failureText', '')[:300])
raise SystemExit(0 if d['result'] == 'Passed' else 1)
" && exit 0 || { [[ $? -eq 1 ]] && exit 1; }
done

# The loop ran out. Say why: a locked screen stops Xcode finalising the bundle.
echo "timed out waiting for a finished .xcresult" >&2
if ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
  echo "  the screen is LOCKED — Xcode can run tests but stalls writing the result bundle; unlock and re-run" >&2
fi
if [[ -n "$bundleNow" && "$bundleNow" != "$bundleBefore" && -d "$bundleNow/Staging" ]]; then
  staged=$(find "$bundleNow/Staging" -name 'Session-*.log' -exec grep -h 'Test run with' {} + 2>/dev/null | tail -1)
  [[ -n "$staged" ]] && echo "  the unfinalised bundle's own log says: ${staged##*console chunk }" >&2
fi
exit 1
