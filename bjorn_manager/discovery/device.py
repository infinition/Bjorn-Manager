"""Device alias manager — assigns stable numbered aliases to discovered Bjorn devices."""

import json
from typing import Optional


class DeviceAliasManager:
    """Maps device IDs to persistent human-readable aliases like 'Bjorn 1'.

    If *path* is given, the mapping is persisted as JSON on disk so aliases
    survive across application restarts.  When *path* is ``None`` the mapping
    lives only in memory (numbering restarts each run).
    """

    def __init__(self, path: Optional[str] = None):
        self.path = path
        self.map: dict[str, str] = {}
        if self.path:
            self._load()

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _load(self) -> None:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                self.map = json.load(f)
        except Exception:
            self.map = {}

    def _save(self) -> None:
        if not self.path:
            return
        try:
            with open(self.path, "w", encoding="utf-8") as f:
                json.dump(self.map, f, indent=2, ensure_ascii=False)
        except Exception:
            pass

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def _next_index(self) -> int:
        """Return the lowest unused Bjorn index (1-based)."""
        used: set[int] = set()
        for alias in self.map.values():
            if alias.lower().startswith("bjorn "):
                try:
                    used.add(int(alias.split()[-1]))
                except Exception:
                    pass
        n = 1
        while n in used:
            n += 1
        return n

    def alias_for(self, device_id: str) -> str:
        """Return the alias for *device_id*, creating one if needed."""
        if device_id in self.map:
            return self.map[device_id]
        alias = f"Bjorn {self._next_index()}"
        self.map[device_id] = alias
        self._save()
        return alias
