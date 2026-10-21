#!/usr/bin/env python3
"""Real CEF local-source integration test, isolated fixtures and a loopback request witness."""
import http.server
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
deadline = time.monotonic() + 60


def remaining(command):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise subprocess.TimeoutExpired(command, 60)
    return seconds


def require(condition, message):
    # Runtime evidence checks must remain active under python -O/PYTHONOPTIMIZE.
    if not condition:
        raise ValueError(message)


run = ROOT / ".build/verification/cef-source" / str(uuid.uuid4())
run.mkdir(parents=True)
project = run / "project"
shutil.copytree(ROOT / "Tests/CEFSourceHarness/fixture", project)
outside = run / "outside.txt"
outside.write_text("outside fixture must not be readable by the page\n")
(project / "outside.txt").symlink_to(outside)
(project / "inside.json").symlink_to(project / "assets/value.json")
shutil.copyfile(project / "assets/value.json", project / "assets/中文 + %.json")
requests = []


class Witness(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"witness")

    def log_message(self, *_args):
        pass  # Requests are retained in witness.json, not discarded.


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Witness)
thread = threading.Thread(target=server.serve_forever)
thread.start()
url = f"http://127.0.0.1:{server.server_port}"
(project / "config.json").write_text(json.dumps({"networkURL": url + "/from-cef", "outsideFileURL": outside.as_uri()}))
print(f"CEF_SOURCE artifacts={run}", flush=True)
status = 1
probe_exit = None
timed_out = False
try:
    # Positive control proves that the local request witness is actually reachable.
    with urllib.request.urlopen(url + "/positive-control", timeout=5) as response:
        require(response.read() == b"witness", "Network witness positive control failed")
    with (run / "build.log").open("w") as output:
        build = ["bash", "scripts/feasibility/cef/build-source-probe.sh"]
        subprocess.run(build, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=remaining(build))
    command = [str(ROOT / ".build/dependencies/cef/CEFSourceProbe.app/Contents/MacOS/CEFSourceProbe"),
               str(project), str(run / "context"), "project-" + run.name + ".invalid"]
    (run / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (run / "probe.log").open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=remaining(command))
        except subprocess.TimeoutExpired:
            timed_out = True
            print(f"ERROR: CEF PID {process.pid} timed out; sending TERM to its test process group", file=sys.stderr, flush=True)
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                print(f"ERROR: CEF PID {process.pid} did not stop after TERM; sending KILL, test remains failed", file=sys.stderr, flush=True)
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        finally:
            probe_exit = process.returncode
    log = (run / "probe.log").read_text()
    if probe_exit != 0:
        raise RuntimeError(f"CEF process exited {probe_exit}; inspect {run / 'probe.log'}")
    results = [json.loads(line.removeprefix("SOURCE_RESULT ")) for line in log.splitlines()
               if line.startswith("SOURCE_RESULT ")]
    expected = {"secureContext", "module", "css", "canvas", "fetch", "unicode", "insideLink", "outsideLink", "missing",
                "network", "fileURL", "classicWorker", "moduleWorker", "sharedWorker", "serviceWorker", "serviceWorkerUnregistered"}
    require(len(results) == 2, f"Expected two complete source rounds, got {len(results)}")
    for result in results:
        require(isinstance(result, dict) and set(result) == expected and all(value is True for value in result.values()),
                f"Invalid source result: {result!r}")
    events = [json.loads(line.removeprefix("SOURCE_EVENT ")) for line in log.splitlines() if line.startswith("SOURCE_EVENT ")]
    ready = [event for event in events if event["kind"] == "context-ready" and event["detail"] == "2"]
    require(len(ready) == 2 and len({event["url"] for event in ready}) == 2, f"Contexts not independently ready: {ready!r}")
    for ready_event in ready:
        origin = ready_event["url"].rstrip("/")
        require(any(event["kind"] in {"request", "factory-request"} and "service-worker" in event["url"]
                    and event["url"].startswith(origin + "/") and not event["browserPresent"] for event in events),
                f"No context-owned Service Worker request for {origin}")
    lifecycle = [line for line in log.splitlines() if line.startswith("SOURCE_ROUND ")]
    require(len(lifecycle) == 4, f"Incomplete round lifecycle: {lifecycle!r}")
    for index, round_number in enumerate((1, 2)):
        require(lifecycle[index * 2].startswith(f"SOURCE_ROUND begin={round_number} "), f"Invalid round order: {lifecycle!r}")
        require(lifecycle[index * 2 + 1] == f"SOURCE_ROUND end={round_number} closed=1 clientDestroyed=1",
                f"Round did not close: {lifecycle!r}")
    for marker, count in {"SOURCE_LIFECYCLE before-close": 2, "SOURCE_LIFECYCLE client-destroyed": 2,
                          "SOURCE_SUMMARY success=1": 2, "SOURCE_LIFECYCLE global-context-initialized": 1,
                          "SOURCE_LIFECYCLE before-shutdown": 1, "SOURCE_LIFECYCLE after-shutdown": 1}.items():
        require(log.count(marker) == count, f"Expected {count} occurrences of {marker!r}")
    require(len([event for event in events if event["kind"] == "context-handler-destroyed"]) == 2,
            "Expected both context handlers to be destroyed")
    require("SOURCE_ISOLATION same=0 sharing=0" in log, "Context isolation comparison missing or failed")
    require(requests == ["/positive-control"], f"Unexpected network requests: {requests!r}")
    print("CEF_SOURCE passed two sequential isolated page contexts in one runtime; real-paint/module/classic/module/shared/service-worker/local-boundary; network witness received only positive control")
    status = 0
except subprocess.TimeoutExpired as error:
    timed_out = True
    print(f"ERROR: CEF source test exceeded its 60-second overall budget: {error.cmd}", file=sys.stderr)
    status = 124
except (subprocess.CalledProcessError, RuntimeError, AssertionError, StopIteration, ValueError) as error:
    print(f"ERROR: {error}; artifacts={run}", file=sys.stderr)
    status = 1
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    (run / "witness.json").write_text(json.dumps(requests, indent=2) + "\n")
    (run / "result.json").write_text(json.dumps({"probe_exit": probe_exit, "test_exit": status, "timed_out": timed_out}) + "\n")
sys.exit(status)
