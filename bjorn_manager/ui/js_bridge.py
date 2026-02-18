"""Thread-safe JavaScript bridge for pywebview.

This module solves the startup crash that plagued earlier versions of BJORN Manager.
The old approach had three fatal flaws:

1. A blind ``time.sleep(10)`` hoping the webview window would be ready.
2. A reentrance guard (``_in_js_call``) that silently **dropped** concurrent
   JS calls instead of queuing them.
3. Direct ``evaluate_js`` calls from multiple Python threads, causing race
   conditions inside the webview runtime.

JSBridge fixes all three by funnelling every JS call through an internal queue
consumed by a single dedicated thread.  Calls made before the window is ready
are buffered automatically and flushed once ``mark_ready()`` is invoked.
"""

from __future__ import annotations

import json
import queue
import threading
from typing import Any


class JSBridge:
    """Thread-safe bridge for calling JavaScript functions from Python threads.

    Uses an internal queue and a dedicated consumer thread to serialise all JS
    calls.  Calls are buffered until the window signals readiness, then the
    queue is flushed in order.

    Typical lifecycle::

        bridge = JSBridge()
        bridge.set_window(window)          # after webview.create_window()
        bridge.call("updateStatus", "…")   # safe even before ready
        bridge.mark_ready()                # after DOMContentLoaded
        …
        bridge.stop()                      # on shutdown
    """

    def __init__(self) -> None:
        self._window: Any = None
        self._ready = threading.Event()
        self._queue: queue.Queue[tuple[str, tuple] | None] = queue.Queue()
        self._consumer_thread: threading.Thread | None = None
        self._stop = threading.Event()

    # ------------------------------------------------------------------
    # Public API – called from any thread
    # ------------------------------------------------------------------

    def set_window(self, window: Any) -> None:
        """Set the pywebview window reference."""
        self._window = window

    def mark_ready(self) -> None:
        """Signal that the window's DOM is loaded and ``BJORNInterface`` exists.

        Starts the consumer thread which will immediately begin draining any
        buffered calls.
        """
        self._ready.set()
        self._stop.clear()
        self._consumer_thread = threading.Thread(
            target=self._consume_loop,
            name="JSBridge-consumer",
            daemon=True,
        )
        self._consumer_thread.start()

    def call(self, function: str, *args: Any) -> None:
        """Queue a JS function call.

        Thread-safe, never blocks the caller, never drops messages.
        """
        self._queue.put((function, args))

    def call_raw(self, js_code: str) -> None:
        """Queue raw JavaScript code for execution."""
        self._queue.put(("__raw__", (js_code,)))

    def stop(self) -> None:
        """Stop the consumer thread gracefully."""
        self._stop.set()
        self._queue.put(None)  # sentinel to unblock the consumer
        if self._consumer_thread is not None and self._consumer_thread.is_alive():
            self._consumer_thread.join(timeout=2)

    # ------------------------------------------------------------------
    # Internal – runs exclusively on the consumer thread
    # ------------------------------------------------------------------

    def _consume_loop(self) -> None:
        """Wait for readiness, then process queued items one at a time."""
        self._ready.wait(timeout=30)
        if not self._ready.is_set():
            print("[ERROR] JSBridge: window never became ready (30 s timeout)")
            return

        while not self._stop.is_set():
            try:
                item = self._queue.get(timeout=0.5)
            except queue.Empty:
                continue

            if item is None:
                break

            function, args = item
            try:
                self._execute(function, args)
            except Exception as exc:  # noqa: BLE001
                print(f"[ERROR] JSBridge consumer: {exc}")

    def _execute(self, function: str, args: tuple) -> None:
        """Translate a queued item into an ``evaluate_js`` call.

        This method is only ever invoked from the single consumer thread,
        so there is no risk of concurrent ``evaluate_js`` calls.
        """
        if self._window is None:
            return

        if function == "__raw__":
            self._window.evaluate_js(args[0])
            return

        js_args = self._serialise_args(args)
        args_str = ", ".join(js_args)
        js_code = (
            f"if (typeof BJORNInterface !== 'undefined' "
            f"&& BJORNInterface.{function}) {{ "
            f"BJORNInterface.{function}({args_str}); }}"
        )
        try:
            self._window.evaluate_js(js_code)
        except Exception as exc:  # noqa: BLE001
            print(f"[ERROR] JSBridge._execute({function}): {exc}")

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _serialise_args(args: tuple) -> list[str]:
        """Convert Python values to their JavaScript literal representations."""
        js_args: list[str] = []
        for arg in args:
            if isinstance(arg, bool):
                js_args.append("true" if arg else "false")
            elif isinstance(arg, (dict, list)):
                js_args.append(json.dumps(arg, default=str))
            elif isinstance(arg, str):
                escaped = (
                    arg.replace("\\", "\\\\")
                    .replace('"', '\\"')
                    .replace("\n", "\\n")
                    .replace("\r", "")
                )
                js_args.append(f'"{escaped}"')
            elif arg is None:
                js_args.append("null")
            else:
                js_args.append(str(arg))
        return js_args
