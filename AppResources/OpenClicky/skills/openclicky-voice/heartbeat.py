#!/usr/bin/env python3
"""
OpenClicky heartbeat sidecar.

Usage: heartbeat.py <socket-path> <project-root> <anchor-pid>

Announces the current project to OpenClicky's global agents.sock and
keeps the connection open as a liveness pipe. Reconnects on drop.
Exits when the anchor pid (the Monitor shell that spawned us) dies.

Mirrors SKI's ski heartbeat.py so users can reuse the same launcher
pattern documented in SKILL.md.
"""
import json
import os
import socket
import sys
import time

RECONNECT_DELAY = 5.0
HEARTBEAT_INTERVAL = 30.0


def anchor_alive(pid: int) -> bool:
    if pid <= 1:
        return True
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: heartbeat.py <socket> <project_root> <anchor_pid>", file=sys.stderr)
        return 2
    sock_path = os.path.expanduser(sys.argv[1])
    project_root = os.path.abspath(sys.argv[2])
    try:
        anchor_pid = int(sys.argv[3])
    except ValueError:
        anchor_pid = 0

    skill_dir = os.path.dirname(os.path.abspath(__file__))
    hello = {
        "hello": "openclicky-heartbeat",
        "project_root": project_root,
        "skill_dir": skill_dir,
        "pid": os.getpid(),
    }
    hello_line = (json.dumps(hello) + "\n").encode("utf-8")

    while anchor_alive(anchor_pid):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(10.0)
            s.connect(sock_path)
            s.sendall(hello_line)
            # Read one ack line (best-effort — ignore contents).
            try:
                _ = s.recv(256)
            except socket.timeout:
                pass
            s.settimeout(None)
            # Keep the connection open. Send a tiny heartbeat byte every
            # HEARTBEAT_INTERVAL so a dead peer surfaces via SIGPIPE.
            while anchor_alive(anchor_pid):
                time.sleep(HEARTBEAT_INTERVAL)
                try:
                    s.sendall(b".")
                except OSError:
                    break
            try:
                s.close()
            except OSError:
                pass
        except (FileNotFoundError, ConnectionRefusedError, OSError):
            # OpenClicky not running or socket bind failed. Try again.
            pass
        if not anchor_alive(anchor_pid):
            break
        time.sleep(RECONNECT_DELAY)
    return 0


if __name__ == "__main__":
    sys.exit(main())
