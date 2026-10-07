#!/usr/bin/env python3
"""Runs every built test bundle, in concurrent lanes. Part of `make test`.

Most of the suite waits (for a page, a shell, a launched app) or works on one
main thread (the hosted UI tiers, WebKit), so bundles run side by side: one
`xcodebuild test-without-building` per lane, against the .xctestrun the last
`build-for-testing` wrote. Every bundle is its own process, so lanes share
nothing but the machine.

What a lane costs: xcodebuild runs a lane's serial bundles one after another,
then starts all its parallelizable ones at once. So a lane takes the sum of its
serial bundles plus the longest of its parallel ones.

A bundle bound to one main thread (a hosted UI tier runs its tests one at a
time; Browser's units queue on WebKit's main thread) goes no faster than that
thread, whatever runs beside it. The only way to share its work is more
processes, so a long serial one is split by suite into shards, each its own
process in its own lane. A parallelizable bundle stays whole: split, Browser's
units took 14.6 s instead of 20.2 alone, but in the full run its two processes
and their web content contended with everything else, and the run finished
later (39 and 43 s against 30 and 32). A shard runs `-only-testing:<bundle>/<suite>` for its suites. One
shard per bundle is the remainder: the bundle, `-skip-testing` the other
shards' suites. A suite added since the last run runs there; one that's gone is
a selection that matches nothing.

The plan: of the ways to split, the one whose lanes finish soonest by the last
run's timings (build/test-results.noindex/durations.json: each bundle's time, and each
suite's share of it). A checkout that has never run the tests (a new worktree)
has none: a serial bundle's suites are then weighed by their tests, as
xcodebuild lists them (`-enumerate-tests`, about 2 s), and a parallel bundle is
guessed by its kind.

The tests' own files: each test process keeps them in a folder of its own,
removed as it exits (Tests/Process/TestTemporary.swift). This removes the
folders of processes that died before they could. A test's web pages keep
theirs in WebKit's container for the app (~/Library/WebKit/<bundle id>), deleted
as the test process exits (WebDataStores), but there Spotlight indexed every
file meanwhile: about 1,600 a run, a sixth of the machine. A Debug build's
container (com.hrusoft.tabs.debug, never an installed Tabs') and the unit tests'
runner's (com.apple.dt.xctest.tool) are made links to `.noindex` folders beside
them, which Spotlight skips.

Writes build/test-results.noindex/: lane-<n>.log and lane-<n>.xcresult per lane, the
merged Tabs.xcresult, durations.json, and lane-<n>.derived: the DerivedData each
lane's xcodebuild logs to (given none, it makes one in ~/Library/Developer/Xcode
for every .xctestrun path, and keeps it). A `.noindex` folder, which Spotlight
skips: a run's result bundles and logs are about 20,000 files.

Usage: Scripts/test-lanes.py [--lanes N] [--plan]
"""

import argparse
import dataclasses
import json
import math
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "build/test-results.noindex"
DURATIONS = RESULTS / "durations.json"
# What one more process of a bundle costs: launching it (a hosted bundle launches the app).
LAUNCH = {True: 2.0, False: 0.5}
# How much sooner a plan must finish to be worth one more process: each launch takes CPU
# from every other lane.
SPLIT_WORTH = 1.0
# A test's time, by whether an app hosts it, until this checkout has run it.
PER_TEST = {True: 0.15, False: 0.05}
SELECTIONS = ("All tests", "Selected tests")


@dataclasses.dataclass(frozen=True)
class Bundle:
    name: str
    parallel: bool
    hosted: bool


@dataclasses.dataclass
class Shard:
    bundle: Bundle
    seconds: float
    suites: tuple = ()  # what it runs; empty: the whole bundle
    remainder: bool = False  # the bundle, less the other shards' suites
    of: int = 1  # how many shards the bundle is in

    def label(self):
        if self.of == 1:
            return self.bundle.name
        part = "rest" if self.remainder else f"{len(self.suites)} suites"
        return f"{self.bundle.name} ({part})"


def xctestrun():
    products = ROOT / "build/DerivedData/Build/Products"
    runs = sorted(products.glob("*.xctestrun"), key=lambda path: path.stat().st_mtime)
    if not runs:
        sys.exit(f"test-lanes: no .xctestrun in {products}: build for testing first (make build-tests)")
    return runs[-1]


def bundles(run):
    """Every test bundle the .xctestrun lists: whether it runs its tests at once, whether an app hosts it."""
    plist = plistlib.loads(run.read_bytes())
    if plist.get("__xctestrun_metadata__", {}).get("FormatVersion", 1) == 1:
        targets = [value | {"BlueprintName": key} for key, value in plist.items() if not key.startswith("__")]
    else:
        targets = [target for configuration in plist["TestConfigurations"] for target in configuration["TestTargets"]]
    return [
        Bundle(target["BlueprintName"], bool(target.get("ParallelizationEnabled")), target.get("TestHostPath", "").endswith(".app"))
        for target in targets
    ]


def load_history():
    history = json.loads(DURATIONS.read_text()) if DURATIONS.exists() else {}
    if "bundles" not in history:  # the older, flat form: bundle times only
        history = {"bundles": history, "suites": {}}
    return history


def listed_suites(run, serial):
    """How many tests each suite of the `serial` bundles has (their own, not their inner
    suites'), as xcodebuild lists them: what a split weighs until there are times."""
    folder = RESULTS / "listing"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    listing = folder / "tests.json"
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(run), "-destination",
               f"platform=macOS,arch={platform.machine()}", "-derivedDataPath", str(listing.parent / "derived"),
               "-enumerate-tests", "-test-enumeration-style", "hierarchical",
               "-test-enumeration-format", "json", "-test-enumeration-output-path", str(listing)]
    subprocess.run(command + [f"-only-testing:{bundle.name}" for bundle in serial], capture_output=True, cwd=ROOT)
    counts = {}

    def walk(node, bundle, path):
        tests = [child for child in node.get("children", []) if child.get("kind") == "test"]
        if tests and path:
            counts.setdefault(bundle, {})["/".join(path)] = len(tests)
        for child in node.get("children", []):
            if child.get("kind") != "test":
                walk(child, bundle, path + [child.get("name", "")])

    try:
        for plan in json.loads(listing.read_text()).get("values", []):
            for target in plan.get("children", []):
                walk(target, target.get("name"), [])
    except (OSError, ValueError):
        pass  # no listing: the bundles run whole this time
    shutil.rmtree(listing.parent, ignore_errors=True)
    return counts


def estimate(bundle, history):
    if bundle.name in history["bundles"]:
        return history["bundles"][bundle.name]
    if bundle.hosted:
        return 60.0
    return 30.0 if bundle.name.endswith(("E2ETests", "EndToEndTests")) else 15.0


def split(bundle, seconds, weights, count):
    """`bundle` as `count` shards, its suites shared longest first; the first is the remainder.

    A suite with suites inside it has tests of its own only the remainder can name (selecting it
    would select the suites inside too), so it stays there."""
    if count < 2 or len(weights) < count:
        return [Shard(bundle, seconds)]
    parents = {path for path in weights if any(other.startswith(path + "/") for other in weights)}
    total = sum(weights.values()) or 1.0
    work = max(seconds - LAUNCH[bundle.hosted], 0.0)
    bins = [[] for _ in range(count)]
    loads = [sum(weights[path] for path in parents)] + [0.0] * (count - 1)
    for path in sorted(set(weights) - parents, key=lambda path: -weights[path]):
        index = loads.index(min(loads))
        bins[index].append(path)
        loads[index] += weights[path]
    return [
        Shard(bundle, work * load / total + LAUNCH[bundle.hosted], tuple(sorted(paths)), remainder=index == 0, of=count)
        for index, (paths, load) in enumerate(zip(bins, loads))
    ]


def lane_time(lane):
    serial = sum(shard.seconds for shard in lane if not shard.bundle.parallel)
    parallel = max((shard.seconds for shard in lane if shard.bundle.parallel), default=0.0)
    return serial + parallel


def place(shards, count):
    """Longest first, each where it adds least to its lane's time (then to the least busy lane);
    never two shards of one bundle in one lane: they'd be one process again."""
    lanes = [[] for _ in range(count)]
    for shard in sorted(shards, key=lambda shard: -shard.seconds):
        allowed = [lane for lane in lanes if all(other.bundle != shard.bundle for other in lane)] or lanes
        def cost(lane):
            after = lane_time(lane + [shard])
            return round(after - lane_time(lane), 3), round(after, 3)

        min(allowed, key=cost).append(shard)
    return [lane for lane in lanes if lane]


def plan(found, history, count):
    """The split whose lanes finish soonest, a second sooner for each process it adds: every
    bundle in as many shards as a lane target asks (no more than lanes), for each target the
    bundles' own times suggest."""
    seconds = {bundle: estimate(bundle, history) for bundle in found}
    targets = sorted({seconds[bundle] / parts for bundle in found for parts in range(1, count + 1)})
    best = None
    for target in targets:
        shards = []
        for bundle in found:
            weights = history["suites"].get(bundle.name, {})
            splittable = weights and not bundle.parallel
            parts = min(count, max(1, math.ceil(seconds[bundle] / target - 1e-9))) if splittable else 1
            shards += split(bundle, seconds[bundle], weights, parts)
        lanes = place(shards, count)
        score = (round(max(map(lane_time, lanes)) + SPLIT_WORTH * (len(shards) - len(found)), 1), len(shards))
        if best is None or score < best[0]:
            best = (score, lanes)
    return best[1]


def arguments(lane, lanes):
    selection = []
    for shard in lane:
        name = shard.bundle.name
        if not shard.suites and not shard.remainder:
            selection.append(f"-only-testing:{name}")
        elif shard.remainder:
            others = [path for other in (s for l in lanes for s in l) if other.bundle == shard.bundle and not other.remainder
                      for path in other.suites]
            selection += [f"-only-testing:{name}"] + [f"-skip-testing:{name}/{path}" for path in others]
        else:
            selection += [f"-only-testing:{name}/{path}" for path in shard.suites]
    return selection


def xcresult(*arguments):
    output = subprocess.run(["xcrun", "xcresulttool", *arguments], capture_output=True, text=True)
    return json.loads(output.stdout) if output.returncode == 0 and output.stdout.strip() else None


def timings(result, names):
    """Each bundle's wall time in a lane, and the time of each suite's own tests."""
    log = xcresult("get", "log", "--path", str(result), "--type", "action")
    launches, suites = {}, {}

    def tests_of(section, bundle, path):
        title = section.get("title", "")
        if title.startswith("Run test case "):
            key = "/".join(path)
            suites.setdefault(bundle, {})[key] = suites.get(bundle, {}).get(key, 0.0) + section.get("duration", 0.0)
            return
        if title.startswith("Run test suite ") and title[15:] not in SELECTIONS:
            path = path + [title[15:]]
        for child in section.get("subsections", []):
            tests_of(child, bundle, path)

    def walk(section):
        title = section.get("title", "")
        if title.startswith("Launch ") and title[7:] in names and "duration" in section:
            launches[title[7:]] = section["duration"]
        if title.startswith("Test target ") and title[12:] in names:
            tests_of(section, title[12:], [])
            return
        for child in section.get("subsections", []):
            walk(child)

    if log:
        walk(log)
    return launches, suites


def temporary_directory():
    """The user's temporary directory, as Foundation finds it."""
    found = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    return Path(found or tempfile.gettempdir())


def unindexed_web_data(run):
    """Points the WebKit container of each app the tests run as at a `.noindex` folder beside it
    (once; what it held moves along): the Debug app's, never an installed Tabs', and the unit
    tests' runner's (com.apple.dt.xctest.tool), which only tests use."""
    plist = plistlib.loads(run.read_bytes())
    identifiers = {"com.apple.dt.xctest.tool"}
    for key, value in plist.items():
        host = "" if key.startswith("__") else value.get("TestHostPath", "")
        info = Path(host.replace("__TESTROOT__", str(run.parent))) / "Contents/Info.plist"
        if host.endswith(".app") and info.exists():
            identifier = plistlib.loads(info.read_bytes()).get("CFBundleIdentifier", "")
            if identifier.endswith(".debug"):
                identifiers.add(identifier)
    for identifier in identifiers:
        container = Path.home() / "Library/WebKit" / identifier
        unindexed = container.with_name(identifier + ".noindex")
        if container.is_symlink():
            continue
        if container.is_dir() and not unindexed.exists():
            container.rename(unindexed)
        elif container.is_dir():
            continue  # both there: leave them to a person
        unindexed.mkdir(parents=True, exist_ok=True)
        container.symlink_to(unindexed.name)


def sweep_test_files():
    """Removes the test-file folders of processes no longer running (Tests/Process/TestTemporary.swift)."""
    root = temporary_directory() / "tabs-tests.noindex"
    for folder in root.glob("*") if root.is_dir() else []:
        try:
            os.kill(int(folder.name), 0)
            continue  # running: a test process of this run or another checkout's
        except ValueError:
            pass  # not a process's folder
        except ProcessLookupError:
            pass
        except PermissionError:
            continue
        shutil.rmtree(folder, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lanes", type=int, default=4)
    parser.add_argument("--plan", action="store_true", help="print the plan and run nothing")
    options = parser.parse_args()

    run = xctestrun()
    found = bundles(run)
    history = load_history()
    unknown = [bundle for bundle in found if not bundle.parallel and bundle.name not in history["suites"]]
    if unknown:
        hosted = {bundle.name: bundle.hosted for bundle in unknown}
        for name, counts in listed_suites(run, unknown).items():
            history["suites"][name] = {path: count * PER_TEST[hosted[name]] for path, count in counts.items()}
            history["bundles"].setdefault(name, sum(history["suites"][name].values()) + LAUNCH[hosted[name]])
    lanes = plan(found, history, options.lanes)
    for index, lane in enumerate(lanes, 1):
        print(f"lane {index} (~{lane_time(lane):.0f}s): {', '.join(shard.label() for shard in lane)}", flush=True)
    if options.plan:
        return 0

    sweep_test_files()
    unindexed_web_data(run)
    RESULTS.mkdir(parents=True, exist_ok=True)
    destination = f"platform=macOS,arch={platform.machine()}"
    started = time.monotonic()
    running = []
    for index, lane in enumerate(lanes, 1):
        result = RESULTS / f"lane-{index}.xcresult"
        log = RESULTS / f"lane-{index}.log"
        derived = RESULTS / f"lane-{index}.derived"
        subprocess.run(["rm", "-rf", str(result), str(derived)], check=True)
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(run), "-destination", destination,
                   "-derivedDataPath", str(derived), "-resultBundlePath", str(result), "-quiet"] + arguments(lane, lanes)
        running.append((index, result, log, subprocess.Popen(command, stdout=log.open("w"), stderr=subprocess.STDOUT, cwd=ROOT)))

    names = {bundle.name for bundle in found}
    launched, suites = {}, {}
    failed = False
    waiting = list(running)
    while waiting:
        finished = [lane for lane in waiting if lane[3].poll() is not None]
        if not finished:
            time.sleep(0.5)
            continue
        index, result, log, process = finished[0]
        waiting.remove(finished[0])
        status = process.returncode
        summary = xcresult("get", "test-results", "summary", "--path", str(result))
        counts = f"{summary['passedTests']} passed, {summary['failedTests']} failed" if summary else "no results"
        print(f"lane {index}: exit {status} after {time.monotonic() - started:.0f}s, {counts}", flush=True)
        for failure in (summary or {}).get("testFailures", []):
            print(f"  FAIL {failure['targetName']}/{failure['testIdentifierString']}: {failure['failureText']}")
        if status != 0:
            failed = True
            if not (summary or {}).get("testFailures"):
                print(f"  lane {index} failed without a test failure; the end of {log.relative_to(ROOT)}:")
                print("".join(log.read_text(errors="replace").splitlines(keepends=True)[-30:]))
        lane_launches, lane_suites = timings(result, names)
        for name, seconds in lane_launches.items():
            launched[name] = launched.get(name, 0.0) + seconds
        for name, times in lane_suites.items():
            suites.setdefault(name, {}).update(times)

    # A split bundle's time is its shards' together: what it would take whole.
    history["bundles"].update({name: round(seconds, 1) for name, seconds in launched.items()})
    history["suites"].update({name: {path: round(seconds, 2) for path, seconds in sorted(times.items())}
                              for name, times in suites.items()})
    DURATIONS.write_text(json.dumps({"bundles": dict(sorted(history["bundles"].items())),
                                     "suites": dict(sorted(history["suites"].items()))}, indent=2) + "\n")
    merged = RESULTS / "Tabs.xcresult"
    subprocess.run(["rm", "-rf", str(merged)], check=True)
    results = [str(result) for _, result, _, _ in running if result.exists()]
    if len(results) > 1:
        subprocess.run(["xcrun", "xcresulttool", "merge", *results, "--output-path", str(merged)], capture_output=True)
    elif results:
        subprocess.run(["cp", "-R", results[0], str(merged)], check=True)
    print(f"test-lanes: {len(found)} bundles in {len(lanes)} lanes, {time.monotonic() - started:.0f}s; "
          f"results in {merged.relative_to(ROOT)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
