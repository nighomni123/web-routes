#!/usr/bin/python3
"""Exchange window choices between one Firefox instance and the local menu."""
import json
import os
from pathlib import Path
import select
import struct
import sys
import tempfile


root = Path.home() / "Library/Application Support/Web Routes/Sessions"
root.mkdir(parents=True, exist_ok=True, mode=0o700)
session = Path(tempfile.mkdtemp(prefix="session-", dir=root))
state = session / "state.json"

def exact(count):
    data = bytearray()
    while len(data) < count:
        part = os.read(0, count - len(data))
        if not part:
            raise EOFError
        data.extend(part)
    return bytes(data)

try:
    while True:
        ready, _, _ = select.select([0], [], [], 0.25)
        if ready:
            length, = struct.unpack("=I", exact(4))
            if length > 2**20:
                break
            windows = json.loads(exact(length))["windows"]
            temp = session / "state.tmp"
            temp.write_text(json.dumps({"pid": os.getpid(), "windows": windows}))
            temp.replace(state)
        for command in sorted(session.glob("cmd-*.json"), key=lambda p: p.stat().st_mtime_ns):
            processing = session / "sending.json"
            command.replace(processing)
            payload = processing.read_bytes()
            processing.unlink()
            sys.stdout.buffer.write(struct.pack("=I", len(payload)) + payload)
            sys.stdout.buffer.flush()
except (EOFError, BrokenPipeError):
    pass
finally:
    for item in session.iterdir():
        item.unlink(missing_ok=True)
    session.rmdir()
