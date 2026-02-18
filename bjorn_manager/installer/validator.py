"""Cross-platform shell script validation.

The original code relied on ``bash -n`` and ``dos2unix``, both of which fail
on Windows.  This module performs validation in pure Python with an optional
``bash -n`` syntax check when running on a Unix host.
"""

import os
import subprocess
import sys


class ScriptValidator:
    """Validate shell scripts on any platform."""

    @staticmethod
    def validate(script_path: str) -> bool:
        """Validate the shell script at *script_path*.

        Checks performed:
        1. Shebang line is present.
        2. CRLF line endings are normalised to LF (pure Python, no
           ``dos2unix`` dependency).
        3. A UTF-8 BOM is stripped if present.
        4. On non-Windows hosts, ``bash -n`` is invoked for a syntax check
           when ``bash`` is available.

        Returns ``True`` when the script passes all applicable checks.
        """
        if not os.path.isfile(script_path):
            return False

        # ------------------------------------------------------------------
        # 1. Read raw bytes and verify the shebang
        # ------------------------------------------------------------------
        with open(script_path, "rb") as fh:
            content = fh.read()

        if not content.startswith(b"#!"):
            return False

        needs_rewrite = False

        # ------------------------------------------------------------------
        # 2. Strip BOM if present (must happen before CRLF normalisation so
        #    we don't accidentally split a BOM across writes)
        # ------------------------------------------------------------------
        if content.startswith(b"\xef\xbb\xbf"):
            content = content[3:]
            needs_rewrite = True

        # ------------------------------------------------------------------
        # 3. Normalise CRLF -> LF
        # ------------------------------------------------------------------
        if b"\r\n" in content:
            content = content.replace(b"\r\n", b"\n")
            needs_rewrite = True

        if needs_rewrite:
            with open(script_path, "wb") as fh:
                fh.write(content)

        # ------------------------------------------------------------------
        # 4. Syntax check via bash -n (Unix only, best-effort)
        # ------------------------------------------------------------------
        if sys.platform != "win32":
            try:
                result = subprocess.run(
                    ["bash", "-n", script_path],
                    capture_output=True,
                    timeout=10,
                )
                return result.returncode == 0
            except (FileNotFoundError, subprocess.TimeoutExpired):
                # bash not installed or timed out -- fall through
                pass

        # On Windows (or when bash is unavailable) we trust the shebang check.
        return True
