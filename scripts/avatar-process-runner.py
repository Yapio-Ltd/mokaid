#!/usr/bin/env python3
"""Run a trusted avatar tool with a deadline, killing the full process group.

Input GLBs never select the command. API credentials are not inherited by tools.
"""
import argparse
import os
import signal
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.timeout not in range(1, 901):
        parser.error("A command and a timeout of 1–900 seconds are required")
    env = {key: os.environ[key] for key in ("PATH", "LD_LIBRARY_PATH", "LANG") if key in os.environ}
    with tempfile.TemporaryDirectory(prefix="avatar-tool-") as home, open(args.log, "wb") as log:
        env.update(HOME=home, TMPDIR=home, OMP_NUM_THREADS="2", OPENBLAS_NUM_THREADS="2")
        process = subprocess.Popen(command, stdout=log, stderr=log, env=env, start_new_session=True)
        def stop_group():
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                return
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            # Children can outlive a cooperative parent; always reap the group.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

        def interrupted(signum, _frame):
            stop_group()
            raise SystemExit(128 + signum)

        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        try:
            return process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            stop_group()
            return 124


if __name__ == "__main__":
    sys.exit(main())
