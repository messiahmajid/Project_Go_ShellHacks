#!/usr/bin/env python3
"""Harness tests: real multi-step tasks on real apps, driven over the socket.

Run Go with the harness socket open, then:
    open -a Go.app --args --harness
    python3 scripts/planner-tests.py            # every task
    python3 scripts/planner-tests.py T1 T4      # a subset

The steps are written by hand, so a pass shows the harness can carry out a
plan (resolve, disambiguate, act and verify) on real apps. Each task is judged
by a separate checker that reads the app's state itself.
"""
import json, os, socket, subprocess, sys, time

SOCKET_PATH = os.path.expanduser("~/Library/Application Support/Go/harness.sock")
REPORT_PATH = "/private/tmp/planner-tests-report.json"


def send(request, timeout=40.0):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(timeout)
    connection.connect(SOCKET_PATH)
    connection.sendall((json.dumps(request) + "\n").encode())
    buffer = b""
    while b"\n" not in buffer:
        chunk = connection.recv(65536)
        if not chunk:
            break
        buffer += chunk
    connection.close()
    return json.loads(buffer.split(b"\n")[0].decode())


class Run:
    """One task's trail: every request as a short record, plus the counters."""

    # Verbs that read "the frontmost app" and so must say which app they mean.
    # `windows` is included because its list only covers the current Space.
    APP_SCOPED_VERBS = {"snapshot", "press", "select", "type", "open", "menu", "menus", "look", "windows"}

    def __init__(self, task_id):
        self.task_id = task_id
        self.records = []
        self.images = 0
        self.rungs = []
        self.app = None
        self.recoveries = 0

    def call(self, request, note="", retried=False):
        # Every app-scoped request names the app the plan is working in, so a
        # focus change between requests can't make it act in the wrong app.
        if self.app and request["verb"] in self.APP_SCOPED_VERBS and "expectApp" not in request:
            request = dict(request, expectApp=self.app)
        request = dict(request, id=f"{self.task_id}-{len(self.records)}")
        started = time.time()
        response = send(request)
        record = {
            "verb": request["verb"],
            "target": request.get("title") or request.get("path") or request.get("app"),
            "ok": response.get("ok"),
            "error": response.get("error"),
            "kernel": (response.get("kernel") or {}).get("decision"),
            "verification": (response.get("verification") or {}).get("status"),
            "ms": int((time.time() - started) * 1000),
            "note": note,
        }
        # A failure records enough to explain itself.
        if not response.get("ok"):
            record["application"] = response.get("application")
            record["resolution"] = response.get("resolution")
            record["reason"] = (response.get("kernel") or {}).get("reason") or response.get("message")
        if response.get("imagePath") or (response.get("escalation") or {}).get("imagePath"):
            self.images += 1
        self.records.append(record)

        # Recovery from a step that failed halfway, bounded to ONE retry and only
        # for a precondition the planner can restore. A kernel refusal is a
        # decision, never retried; a second frontmostChanged is reported as is.
        if response.get("error") == "frontmostChanged" and not retried:
            self.recoveries += 1
            self.call({"verb": "focus", "app": self.app}, note="recover: re-pin focus")
            time.sleep(0.8)
            return self.call({k: v for k, v in request.items() if k != "id"}, note="recover: retry once", retried=True)
        return response

    def focus(self, app):
        # Pin the front app; it becomes the expectApp of later app-scoped requests.
        self.app = app
        self.call({"verb": "focus", "app": app}, note="pin focus")

    def names(self):
        snapshot = self.call({"verb": "snapshot"}, note="checker read")
        return {e["name"] for e in (snapshot.get("elements") or []) if e.get("nameIsPlausibleLabel")}

    def window_titles(self, app):
        windows = self.call({"verb": "windows", "app": app}, note="checker read")
        return [w["title"] for w in (windows.get("windows") or []) if w.get("role") == "AXWindow"]

    def act_resolving_ambiguity(self, request, choose):
        """Issue an intent; if it is ambiguous, climb the published ladder.

        `choose` picks the intended candidate from a list of candidate
        summaries — the planner's judgement, written down per task.
        """
        response = self.call(request)
        if response.get("error") != "ambiguous":
            self.rungs.append("structure" if response.get("ok") else f"refused:{response.get('error')}")
            return response

        # Rung 1: a container name, proven by the harness to pick exactly one.
        for candidate in response.get("candidates") or []:
            if choose(candidate) and candidate.get("suggestedWithinNamed"):
                self.rungs.append("withinNamed")
                return self.call(dict(request, withinNamed=candidate["suggestedWithinNamed"]),
                                 note="rung 1: withinNamed")

        # Rung 2: a picture, and a point proven to lie inside one candidate only.
        escalated = self.call(dict(request, escalate=True), note="rung 2: escalate")
        for candidate in (escalated.get("escalation") or {}).get("candidates") or []:
            if choose(candidate) and candidate.get("suggestedPoint"):
                self.rungs.append("nearPoint")
                return self.call(dict(request, nearPoint=candidate["suggestedPoint"]),
                                 note="rung 2: nearPoint")

        self.rungs.append("unresolved")
        return escalated


def settings_running():
    return subprocess.run(["pgrep", "-x", "System Settings"], capture_output=True).returncode == 0


def open_settings_fresh(run, deadline_seconds=8.0):
    """Quit System Settings, wait until it is really gone, then `launch` it over the socket.

    Relaunching straight after a quit can race it, so the quit is polled against
    a deadline, and `launch` waits until the app is in front with a window.

    The launch goes through the harness so it is audited and kernel-checked
    like every other step. The quit stays outside: there is no quit verb.
    """
    subprocess.run(["osascript", "-e", 'quit app "System Settings"'])
    until = time.time() + deadline_seconds
    while settings_running() and time.time() < until:
        time.sleep(0.2)
    if run.call({"verb": "launch", "app": "System Settings"}, note="launch and wait").get("status") != "ready":
        return False
    # Same as Run.focus: the app just launched is the one every later
    # app-scoped request must name, or the frontmost guard never runs.
    run.app = "System Settings"
    time.sleep(1.0)
    return True


def close_settings():
    subprocess.run(["osascript", "-e", 'quit app "System Settings"'])


def check(condition, message, failures):
    if not condition:
        failures.append(message)


# ---------------------------------------------------------------- tasks

def task_finder_navigate_and_back(run, failures):
    """Open a window, navigate by the sidebar, come back, close. Reversible."""
    run.focus("Finder")
    before_count = len(run.window_titles("Finder"))
    run.call({"verb": "menu", "path": ["File", "New Finder Window"]}); time.sleep(1.2)
    start_title = (run.window_titles("Finder") or [None])[0]
    try:
        run.act_resolving_ambiguity({"verb": "select", "title": "Documents"},
                                    choose=lambda c: c.get("role") == "AXStaticText"); time.sleep(1.0)
        check((run.window_titles("Finder") or [None])[0] == "Documents",
              "window did not show Documents after selecting it", failures)
        run.call({"verb": "menu", "path": ["Go", "Back"]}); time.sleep(1.0)
        check((run.window_titles("Finder") or [None])[0] == start_title,
              f"Go > Back did not return to {start_title!r}", failures)
    finally:
        run.focus("Finder")
        run.call({"verb": "menu", "path": ["File", "Close Window"]}, note="cleanup"); time.sleep(0.8)
    check(len(run.window_titles("Finder")) == before_count, "window count not restored", failures)


def task_finder_ambiguous_sidebar_row(run, failures):
    """On the Recent window, "Recent" names the window AND its sidebar label.

    Stays on Recent, where the name is genuinely ambiguous, and checks that the
    element the harness acted on is the candidate chosen, compared by frame.
    """
    run.focus("Finder")
    run.call({"verb": "menu", "path": ["File", "New Finder Window"]}); time.sleep(1.2)
    try:
        check((run.window_titles("Finder") or [None])[0] == "Recent",
              "setup: new window did not open on Recent", failures)
        chosen = {}

        def sidebar_label(candidate):
            wanted = candidate.get("role") == "AXStaticText" and (
                candidate.get("suggestedWithinNamed") == "sidebar" or candidate.get("suggestedPoint"))
            if wanted:
                chosen["frame"] = candidate.get("frame")
            return wanted

        response = run.act_resolving_ambiguity({"verb": "select", "title": "Recent"}, choose=sidebar_label)
        time.sleep(1.0)
        check(run.rungs and run.rungs[-1] in ("withinNamed", "nearPoint"),
              f"'Recent' was not ambiguous on the Recent window (rung {run.rungs[-1:]}); task tested nothing",
              failures)
        check(chosen.get("frame") is not None and (response.get("resolved") or {}).get("frame") == chosen["frame"],
              "the harness acted on a different element than the candidate the planner chose", failures)
        # The row is already selected, so the honest answer is "already there":
        # nothing written and nothing to verify.
        performed = (response.get("performed") or {}).get("status")
        verification = (response.get("verification") or {}).get("status")
        check(performed == "alreadySelected" and verification == "notNeeded",
              f"an already-selected row was reported as performed={performed!r} verification={verification!r}",
              failures)
        check((run.window_titles("Finder") or [None])[0] == "Recent", "window left Recent", failures)
    finally:
        run.focus("Finder")
        run.call({"verb": "menu", "path": ["File", "Close Window"]}, note="cleanup"); time.sleep(0.8)


def task_settings_pane_navigation(run, failures):
    """North-star app: move between panes, checked by labels only that pane shows."""
    try:
        check(open_settings_fresh(run), "System Settings did not come up", failures)
        run.act_resolving_ambiguity({"verb": "select", "title": "Displays"},
                                    choose=lambda c: c.get("role") in ("AXStaticText", "AXRow")); time.sleep(1.2)
        check({"Night Shift…", "Brightness"} & run.names(), "Displays pane not showing", failures)
        run.focus("System Settings")
        run.act_resolving_ambiguity({"verb": "select", "title": "General"},
                                    choose=lambda c: c.get("role") in ("AXStaticText", "AXRow")); time.sleep(1.2)
        check({"About", "Storage", "Software Update"} & run.names(), "General pane not showing", failures)
    finally:
        close_settings()


def task_settings_search_typing(run, failures):
    """Typing into an anonymous field, aimed by focus. Nothing is saved to disk.

    After launch, focus is on the sidebar, where typing is refused. So the
    test presses View > Search, then types where focus now is.
    """
    try:
        check(open_settings_fresh(run), "System Settings did not come up", failures)
        run.call({"verb": "menu", "path": ["View", "Search"]}, note="put focus in search"); time.sleep(0.6)
        response = run.call({"verb": "type", "target": "focused", "text": "Night Shift", "mode": "replace"})
        run.rungs.append("focus" if response.get("ok") else f"refused:{response.get('error')}")
        time.sleep(1.0)
        check("Night Shift" in run.names(), "search field does not hold the typed text", failures)
    finally:
        close_settings()


def task_irreversible_is_refused(run, failures):
    """True negative: the planner asks for something with no undo, and insists."""
    run.focus("Finder")
    response = run.call({"verb": "menu", "path": ["Finder", "Empty Bin…"], "confirmed": True})
    reason = str((response.get("kernel") or {}).get("reason"))
    run.rungs.append(f"refused:{response.get('error')}")
    check(response.get("ok") is False and reason.startswith("refusing an irreversible action"),
          f"Empty Bin was not hard-refused (got {response.get('error')}: {reason[:80]})", failures)


def task_published_name_mismatch(run, failures):
    """Documented limit, not a bug to hide: 'Wi-Fi' as typed is not the name published."""
    try:
        check(open_settings_fresh(run), "System Settings did not come up", failures)
        ascii_name = run.call({"verb": "select", "title": "Wi-Fi"})
        run.rungs.append(f"refused:{ascii_name.get('error')}")
        check(ascii_name.get("error") == "notFound",
              "ASCII 'Wi-Fi' resolved — the documented limit changed; update this task", failures)
    finally:
        close_settings()


TASKS = {
    "T1": ("Finder: navigate by sidebar and back", task_finder_navigate_and_back),
    "T2": ("Finder: ambiguous sidebar label, resolved by the ladder", task_finder_ambiguous_sidebar_row),
    "T3": ("System Settings: pane navigation", task_settings_pane_navigation),
    "T4": ("System Settings: type into the anonymous search field", task_settings_search_typing),
    "T5": ("True negative: Empty Bin with confirmed=true is refused", task_irreversible_is_refused),
    "T6": ("Documented limit: ASCII 'Wi-Fi' is not the published name", task_published_name_mismatch),
}


def main():
    selected = sys.argv[1:] or list(TASKS)
    previous = send({"id": "pre", "verb": "ping"})
    if not previous.get("ok"):
        sys.exit("harness is not answering — launch Go with --harness first")

    results = []
    for task_id in selected:
        title, body = TASKS[task_id]
        run, failures, started = Run(task_id), [], time.time()
        try:
            body(run, failures)
        except Exception as error:  # a crashed task is a failed task, never a skipped one
            failures.append(f"task raised {type(error).__name__}: {error}")
        results.append({
            "task": task_id, "title": title, "passed": not failures, "failures": failures,
            "seconds": round(time.time() - started, 1), "requests": len(run.records),
            "rungs": run.rungs, "images": run.images, "recoveries": run.recoveries,
            "historyBytes": len(json.dumps(run.records)), "records": run.records,
        })

    send({"id": "post", "verb": "focus", "app": "Claude"})
    with open(REPORT_PATH, "w") as report:
        json.dump(results, report, indent=1)

    print(f"{'task':<4} {'result':<6} {'secs':>5} {'reqs':>4} {'imgs':>4} {'recov':>5} {'hist B':>6}  rungs / failures")
    for r in results:
        detail = ", ".join(r["rungs"]) + ("" if r["passed"] else "  |  " + "; ".join(r["failures"]))
        print(f"{r['task']:<4} {'PASS' if r['passed'] else 'FAIL':<6} {r['seconds']:>5} "
              f"{r['requests']:>4} {r['images']:>4} {r['recoveries']:>5} {r['historyBytes']:>6}  {detail}")
    passed = sum(r["passed"] for r in results)
    print(f"\n{passed} of {len(results)} passed — full trail in {REPORT_PATH}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
