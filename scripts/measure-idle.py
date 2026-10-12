#!/usr/bin/env python3
"""Measures the real resident app externally; no sampler or polling is installed in the app."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description="Measure menu readiness and a real idle interval.")
    parser.add_argument("binary", type=Path)
    parser.add_argument("--duration", type=float, default=7200)
    parser.add_argument("--interval", type=float, default=60)
    parser.add_argument("--wait-for-exit", action="store_true", help="Keep the launcher alive after sampling until the app exits normally.")
    parser.add_argument("--output", type=Path, default=Path("build/evidence/B9-idle.json"))
    args = parser.parse_args()
    if args.duration <= 0 or args.interval <= 0 or not args.binary.is_file():
        parser.error("Use an existing app binary and positive duration/interval.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    ready = args.output.with_suffix(".ready")
    ready.unlink(missing_ok=True)
    env = os.environ.copy()
    env["NIKO_STARTUP_METRICS"] = str(ready.resolve())
    env["NIKO_TEARDOWN_METRICS"] = str(args.output.with_suffix(".teardown.json").resolve())
    env["NIKO_DISPLAYLINK_METRICS"] = str(args.output.with_suffix(".displaylink.json").resolve())
    env["NIKO_CAPTURE_METRICS"] = str(args.output.with_suffix(".capture.json").resolve())
    with args.output.with_suffix(".stdout.log").open("wb") as out, args.output.with_suffix(".stderr.log").open("wb") as err:
        launched = time.monotonic()
        process = subprocess.Popen([str(args.binary.resolve())], env=env, stdout=out, stderr=err)
    while not ready.exists():
        if process.poll() is not None or time.monotonic() - launched > 10:
            raise RuntimeError("The app exited or failed to emit MenuReady within ten seconds.")
        time.sleep(0.01)
    cold_ms = (float(ready.read_text()) - launched) * 1000
    time.sleep(10)
    started = time.monotonic()
    samples = []
    report = {
        "measuredAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "binary": str(args.binary.resolve()), "pid": process.pid,
        "binarySHA256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "menuReadyMilliseconds": cold_ms, "requestedIdleSeconds": args.duration,
        "method": "MenuReady monotonic timestamp; external ps RSS/%CPU sampling",
        "samples": samples,
    }
    while True:
        exit_code = process.poll()
        if exit_code is not None:
            report.update({"completed": False, "interrupted": True,
                           "interruptionReason": "The app exited before the requested idle interval completed.",
                           "processExitCode": exit_code})
            args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            raise RuntimeError("The app exited early; the idle interval did not pass.")
        result = subprocess.run(["/bin/ps", "-o", "rss=,%cpu=", "-p", str(process.pid)],
                                capture_output=True, text=True, check=True)
        rss, cpu = result.stdout.split()
        elapsed = time.monotonic() - started
        samples.append({"elapsedSeconds": elapsed, "rssKiB": int(rss), "cpuPercent": float(cpu)})
        report["observedIdleSeconds"] = elapsed
        report["maximumRSSKiB"] = max(item["rssKiB"] for item in samples)
        report["rssChangeKiB"] = samples[-1]["rssKiB"] - samples[0]["rssKiB"]
        report["completed"] = elapsed >= args.duration
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        if report["completed"]:
            print(json.dumps({key: value for key, value in report.items() if key != "samples"}, ensure_ascii=False), flush=True)
            if args.wait_for_exit:
                process.wait()
            return
        time.sleep(min(args.interval, args.duration - elapsed))


if __name__ == "__main__":
    main()
