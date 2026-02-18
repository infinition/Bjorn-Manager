"""UI layer for BJORN Manager.

Exports the thread-safe JavaScript bridge used to communicate with the
pywebview frontend.
"""

from bjorn_manager.ui.js_bridge import JSBridge

__all__ = ["JSBridge"]
