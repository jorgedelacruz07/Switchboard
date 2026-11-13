"""Temporary macOS footprint sampler; never part of the resident application."""
import argparse
import ctypes
import json
from pathlib import Path
import struct
import subprocess
import time


def footprint(pid):
    # Darwin rusage_info_v2 starts with UUID[16], then UInt64 counters. The eighth
    # counter is ri_phys_footprint. Allocate ample space for the entire v2 result.
    buffer = ctypes.create_string_buffer(4096)
    if LIBPROC.proc_pid_rusage(pid, 2, ctypes.byref(buffer)) != 0:
        return None
    return struct.unpack_from("Q", buffer.raw, 72)[0] / 1048576


def sample(app):
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True)
    processes = {}
    for row in rows.splitlines():
        fields = row.strip().split(None, 2)
        if len(fields) == 3:
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    roots = {pid for pid, (_, executable) in processes.items() if executable == str(app)}
    descendants = set(roots)
    while True:
        extended = descendants | {pid for pid, (parent, _) in processes.items() if parent in descendants}
        if extended == descendants:
            break
        descendants = extended
    values = {pid: footprint(pid) for pid in descendants}
    main = sum(value for pid, value in values.items() if pid in roots and value is not None)
    helpers = sum(value for pid, value in values.items() if pid not in roots and value is not None)
    return bool(roots), main, helpers, len(descendants - roots)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Measure Switchboard and its transient child processes.")
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=20)
    parser.add_argument("--wait", type=float, default=30)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
    stop_waiting = time.monotonic() + args.wait
    started = None
    main_peak = helper_peak = combined_peak = main_last = 0
    max_helpers = samples = 0
    while True:
        found, main, helper, count = sample(args.app.resolve())
        if found:
            if started is None:
                started = time.monotonic()
            samples += 1
            main_last = main
            main_peak = max(main_peak, main)
            helper_peak = max(helper_peak, helper)
            combined_peak = max(combined_peak, main + helper)
            max_helpers = max(max_helpers, count)
        if started is not None and time.monotonic() - started >= args.seconds:
            break
        if started is None and time.monotonic() >= stop_waiting:
            raise SystemExit("The target app was not running before the wait deadline.")
        time.sleep(0.1)
    result = {
        "samples": samples,
        "duration_seconds": round(time.monotonic() - started, 1),
        "main_last_MiB": round(main_last, 2),
        "main_sampled_peak_MiB": round(main_peak, 2),
        "helpers_sampled_peak_MiB": round(helper_peak, 2),
        "combined_sampled_peak_MiB": round(combined_peak, 2),
        "max_helpers": max_helpers,
        "sampling_note": "Sampled every ~0.1s; shorter allocation spikes may be missed.",
    }
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    print(text, end="")
