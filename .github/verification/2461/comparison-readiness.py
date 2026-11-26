"""Bounded, evidence-producing simulator readiness gate. Never erase/recreate a runtime."""
import json, os, re, signal, subprocess, sys, time
from pathlib import Path

mode, udid, directory, *args = sys.argv[1:]
out = Path(directory)
out.mkdir(parents=True, exist_ok=True)
runtime_id = "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"
model = "Apple TV 4K (3rd generation)"

def call(name, cmd, timeout=60):
    with (out / (name + ".log")).open("w") as f:
        f.write("$ " + repr(cmd) + "\n"); f.flush()
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, errors="replace", start_new_session=True)
        try:
            s, _ = p.communicate(timeout=timeout)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            s, _ = p.communicate()
            rc = 124
        f.write(s); f.write(f"\nEXIT {rc}\n")
    if rc:
        raise RuntimeError(f"{name}: exit {rc}")
    return s

def sim(name, *cmd, timeout=60):
    return call(name, ["xcrun", "simctl", *cmd], timeout)

def device(tag):
    rt = json.loads(sim(tag + "-runtimes", "list", "-j", "runtimes"))
    assert any(r.get("identifier") == runtime_id and r.get("isAvailable")
               and r.get("buildversion") == "24J360" for r in rt["runtimes"]), "Exact runtime unavailable"
    ds = json.loads(sim(tag + "-devices", "list", "-j", "devices"))
    found = [x for x in ds["devices"].get(runtime_id, []) if x["udid"] == udid]
    assert len(found) == 1 and found[0]["name"] == model and found[0]["isAvailable"], "Exact device unavailable"
    return found[0]["state"]

def ready(tag):
    state = device(tag + "-before")
    if state == "Shutdown":
        sim(tag + "-boot", "boot", udid, timeout=90)
    elif state not in ("Booting", "Booted"):
        raise RuntimeError("Unexpected simulator state: " + state)
    sim(tag + "-bootstatus", "bootstatus", udid, "-b", timeout=150)
    assert device(tag + "-after") == "Booted", "Device did not reach Booted"
    sim(tag + "-launchctl", "spawn", udid, "launchctl", "list", timeout=30)
    result = call(tag + "-destinations", ["xcodebuild", *args, "-showdestinations"], 120)
    # Only a positive eligible-list match counts; reject placeholders/ineligible entries.
    eligible = False
    matches = []
    for line in result.splitlines():
        if re.search(r"(Available destinations|Destinations compatible)", line, re.I):
            eligible = True
        elif re.search(r"Ineligible destinations", line, re.I):
            eligible = False
        elif eligible and re.search(r"\bid:\s*" + re.escape(udid) + r"\b", line, re.I):
            if "platform:tvOS Simulator" in line and re.search(r"\barch:\s*arm64\b", line):
                matches.append(line.strip())
    assert matches, "Exact arm64 tvOS simulator not in eligible Xcode destinations"
    (out / "eligible-destination.txt").write_text("\n".join(matches) + "\n")

def reset():
    # A hosted, disposable runner only. Preserve installed runtime and device.
    # The app and test runner use app-local storage; the app also stores tokens in keychain.
    import plistlib
    products = Path(os.environ["COMPARISON_PRODUCTS"])
    bundles = [products / "Swiftfin.app", products / "Swiftfin tvOS Screenshots-Runner.app"]
    ids = [plistlib.loads((p / "Info.plist").read_bytes())["CFBundleIdentifier"] for p in bundles]
    def apps(tag):
        return sim(tag, "listapps", udid)
    def installed(raw, bundle):
        return bool(re.search(r'(?m)^\s*"?'+re.escape(bundle)+r'"?\s*=', raw))
    before = apps("apps-before")
    for i, bundle in enumerate(ids):
        if installed(before, bundle):
            sim(f"uninstall-{i}", "uninstall", udid, bundle)
    sim("keychain-reset", "keychain", udid, "reset")
    after = apps("apps-after")
    assert all(not installed(after, bundle) for bundle in ids), "App or runner still installed"
    (out / "reset-bundles.json").write_text(json.dumps(ids, indent=2) + "\n")

errors = []
for attempt in range(1, 3):
    try:
        ready(f"attempt-{attempt}")
        if mode == "scenario":
            reset()
            ready(f"attempt-{attempt}-post-reset")
        (out / "status.json").write_text(json.dumps({"status":"PASS","mode":mode,"udid":udid,"runtime":runtime_id,"runtime_build":"24J360","model":model,"attempt":attempt},indent=2)+"\n")
        print(f"PASS {mode}: Booted, responsive, exact Xcode destination eligible")
        sys.exit(0)
    except Exception as e:
        errors.append(str(e))
        print(f"Readiness attempt {attempt}: {e}", flush=True)
        if attempt == 1: time.sleep(10)
(out / "status.json").write_text(json.dumps({"status":"BLOCKED","mode":mode,"udid":udid,"errors":errors},indent=2)+"\n")
sys.exit(1)
