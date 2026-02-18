# -*- coding: utf-8 -*-
"""Entry point: python -m bjorn_manager"""
import sys
import os
import io

os.environ["PYTHONUTF8"] = "1"

def _force_utf8_stream(stream):
    if stream and hasattr(stream, "detach"):
        try:
            return io.TextIOWrapper(stream.detach(), encoding="utf-8", errors="replace")
        except Exception:
            return stream
    return stream

sys.stdout = _force_utf8_stream(sys.stdout)
sys.stderr = _force_utf8_stream(sys.stderr)

from bjorn_manager.app import main

if __name__ == "__main__":
    main()
