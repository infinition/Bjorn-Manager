"""Network discovery for Bjorn devices.

Combines mDNS browsing, CIDR TCP scanning, and periodic port-8000
polling to locate Bjorn devices on USB, Bluetooth, and LAN interfaces.

Key improvements over v10
-------------------------
* ``_seen_ips`` is protected by a ``threading.Lock`` — it is mutated from
  mDNS callbacks, CIDR scan workers, and the port-8000 poller concurrently.
* ``Zeroconf()`` is created inside ``start()``, not ``__init__()`` — avoids
  leaking sockets when ``start()`` is never called.
* ``reset()`` performs a clean stop-then-start cycle.
* ``_port8000_poll`` probes IPs in parallel via a ``ThreadPoolExecutor``.
* ``strict_bjorn_only`` is a constructor parameter (default ``True``).
"""

from __future__ import annotations

import ipaddress
import queue
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Callable, Optional

import netifaces
from zeroconf import ServiceBrowser, Zeroconf

from bjorn_manager.discovery.device import DeviceAliasManager


class Discovery:
    """Discover Bjorn devices on the local network.

    Parameters
    ----------
    api_callback:
        ``callback(event_type, *args)`` invoked for discovery events:

        * ``('log', message, level)``
        * ``('device_found', alias, ip, has_webapp)``
        * ``('device_gone', ip)``
        * ``('webapp_status', ip, up_bool)``
    strict_bjorn_only:
        When ``True`` (default) only devices whose hostname matches known
        Bjorn naming patterns are emitted.
    """

    def __init__(
        self,
        api_callback: Optional[Callable] = None,
        strict_bjorn_only: bool = True,
    ):
        self.api_callback = api_callback
        self.strict_bjorn_only = strict_bjorn_only

        # Zeroconf instance — created lazily in start()
        self.zeroconf: Optional[Zeroconf] = None
        self.browsers: list[ServiceBrowser] = []

        # Thread-safe set of discovered IPs
        self._seen_ips: set[str] = set()
        self._seen_ips_lock = threading.Lock()

        # Internal state
        self._stop = False
        self._cidr_thread: Optional[threading.Thread] = None
        self._port8000_thread: Optional[threading.Thread] = None
        self._sweeper_thread: Optional[threading.Thread] = None

        # Alias numbering restarts each run (no persistence path)
        self.alias_mgr = DeviceAliasManager(path=None)

        self._id_by_ip: dict[str, str] = {}
        self._web_status_prev: dict[str, bool] = {}
        # device_key -> {"alias": str, "ips": set[str], "last_seen": float}
        self._registry: dict[str, dict] = {}
        self._registry_lock = threading.Lock()
        self._stale_timeout: float = 90  # seconds before visual removal

        # IPs to always ignore (gateways, routers, self)
        self._ignored_ips: set[str] = set()
        self._build_ignored_ips()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Begin discovery (mDNS + CIDR scan + sweeper)."""
        self._stop = False
        self._log("[DEBUG] Starting network discovery...")

        # Create Zeroconf here to avoid socket leak if start() is never called
        try:
            self.zeroconf = Zeroconf()
        except Exception as exc:
            self._log(f"[DEBUG] Zeroconf init failed: {exc}", "error")
            self.zeroconf = None

        # mDNS service browsers
        if self.zeroconf is not None:
            try:
                self.browsers = []
                for stype in ("_ssh._tcp.local.", "_workstation._tcp.local."):
                    browser = ServiceBrowser(
                        self.zeroconf, stype, handlers=[self._on_service]
                    )
                    self.browsers.append(browser)
                self._log("[DEBUG] mDNS browsers started")
            except Exception as exc:
                self._log(f"[DEBUG] mDNS browser failed: {exc}", "error")

        # CIDR scan thread
        try:
            self._cidr_thread = threading.Thread(
                target=self._scan_cidr_loop, daemon=True
            )
            self._cidr_thread.start()
            self._log("[DEBUG] CIDR scan thread started")
        except Exception as exc:
            self._log(f"[DEBUG] CIDR scan failed: {exc}", "error")

        # Sweeper thread
        try:
            self._sweeper_thread = threading.Thread(
                target=self._sweeper_loop, daemon=True
            )
            self._sweeper_thread.start()
        except Exception as exc:
            self._log(f"[DEBUG] Sweeper start failed: {exc}", "error")

    def stop(self) -> None:
        """Stop all discovery activity and release resources."""
        self._log("[DEBUG] Stopping network discovery...")
        self._stop = True

        if self._cidr_thread and self._cidr_thread.is_alive():
            self._cidr_thread.join(timeout=2)
        if self._port8000_thread and self._port8000_thread.is_alive():
            self._port8000_thread.join(timeout=2)
        if self._sweeper_thread and self._sweeper_thread.is_alive():
            self._sweeper_thread.join(timeout=2)

        for browser in self.browsers:
            try:
                browser.cancel()
            except Exception:
                pass
        self.browsers.clear()

        if self.zeroconf is not None:
            try:
                self.zeroconf.close()
            except Exception:
                pass
            self.zeroconf = None

        self._log("[DEBUG] Network discovery stopped")

    def reset(self) -> None:
        """Stop discovery, clear all state, and restart cleanly."""
        self.stop()

        with self._seen_ips_lock:
            self._seen_ips.clear()
        with self._registry_lock:
            self._registry.clear()
        self._id_by_ip.clear()
        self._web_status_prev.clear()
        self.alias_mgr = DeviceAliasManager(path=None)

        self._cidr_thread = None
        self._port8000_thread = None
        self._sweeper_thread = None

        self.start()

    # ------------------------------------------------------------------
    # mDNS callback
    # ------------------------------------------------------------------

    def _on_service(
        self, zeroconf: Zeroconf, service_type: str, name: str, state_change
    ) -> None:
        try:
            info = zeroconf.get_service_info(service_type, name, 2000)
            if not info:
                return
            for addr in info.addresses or []:
                try:
                    ip = socket.inet_ntoa(addr)
                except Exception:
                    continue
                server = (info.server or info.name or "").rstrip(".")
                label = server if server else "bjorn"
                if self.strict_bjorn_only and not self._is_bjorn_hostname(server):
                    return
                self._emit_device(label, ip)
        except Exception:
            pass

    # ------------------------------------------------------------------
    # TCP probe
    # ------------------------------------------------------------------

    @staticmethod
    def _probe_tcp(host: str, port: int, timeout: float = 0.6) -> bool:
        """Return ``True`` if a TCP connection to *host*:*port* succeeds."""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect((host, port))
            sock.close()
            return True
        except Exception:
            return False

    # ------------------------------------------------------------------
    # Device emission
    # ------------------------------------------------------------------

    def _emit_device(self, label: str, ip: str) -> None:
        """Register a discovered device and notify the callback if new."""
        if self._is_ignored_ip(ip):
            return

        with self._seen_ips_lock:
            self._seen_ips.add(ip)

        host = self._normalize_host(label or self._reverse_hostname(ip))
        if self.strict_bjorn_only and not self._is_bjorn_hostname(host):
            return

        device_key = self._device_key(host, ip)
        tag = self._ip_tag(ip)

        # Persistent alias by device_key (same number on USB/LAN)
        base_alias = self.alias_mgr.alias_for(device_key)
        alias = f"{base_alias} ({tag})"

        now = time.time()

        with self._registry_lock:
            rec = self._registry.get(device_key)
            is_new_device = rec is None
            is_new_ip_for_device = False

            if rec is None:
                rec = {"alias": base_alias, "ips": set(), "last_seen": now}
                self._registry[device_key] = rec

            if ip not in rec["ips"]:
                rec["ips"].add(ip)
                is_new_ip_for_device = True

            rec["last_seen"] = now

        # Only emit for genuinely new entries (device or new IP)
        if is_new_device or is_new_ip_for_device:
            has_webapp = self._probe_tcp(ip, 8000, timeout=0.35)
            if self.api_callback:
                self.api_callback("device_found", alias, ip, has_webapp)

    # ------------------------------------------------------------------
    # CIDR scan
    # ------------------------------------------------------------------

    def _scan_cidr_loop(self) -> None:
        """Scan well-known subnets and the gateway /24 for SSH (port 22)."""
        self._log("[DEBUG] CIDR scan started")

        networks: list[ipaddress.IPv4Network] = []
        try:
            gw_net = self._get_gateway_cidr()
            if gw_net:
                networks.append(gw_net)
        except Exception:
            pass
        for cidr in ("172.20.1.0/24", "172.20.2.0/24"):
            try:
                networks.append(ipaddress.ip_network(cidr, strict=False))
            except Exception:
                pass

        for network in networks:
            if self._stop:
                break
            hosts = list(network.hosts())
            q: queue.Queue[str] = queue.Queue()
            for host in hosts:
                q.put(str(host))

            def worker() -> None:
                while not self._stop:
                    try:
                        ip = q.get_nowait()
                    except queue.Empty:
                        break
                    if self._probe_tcp(ip, 22, timeout=0.4):
                        hostname = self._reverse_hostname(ip) or ""
                        self._emit_device(hostname, ip)

            threads = [
                threading.Thread(target=worker, daemon=True) for _ in range(24)
            ]
            for t in threads:
                t.start()
            for t in threads:
                t.join()

        self._log("[DEBUG] CIDR scan completed")

        # Start the port-8000 poller once the initial scan is done
        if not self._stop and self._port8000_thread is None:
            self._port8000_thread = threading.Thread(
                target=self._port8000_poll, daemon=True
            )
            self._port8000_thread.start()

    # ------------------------------------------------------------------
    # Port 8000 webapp polling (parallel)
    # ------------------------------------------------------------------

    def _port8000_poll(self) -> None:
        """Periodically probe all seen IPs for port 8000 (webapp) status.

        Probes run in parallel using a thread pool (max 8 workers).
        """
        while not self._stop:
            with self._seen_ips_lock:
                ips = list(self._seen_ips)

            if ips:
                with ThreadPoolExecutor(max_workers=8) as pool:
                    futures = {
                        pool.submit(self._probe_tcp, ip, 8000, 0.35): ip
                        for ip in ips
                    }
                    for future in as_completed(futures):
                        if self._stop:
                            break
                        ip = futures[future]
                        try:
                            up = future.result()
                        except Exception:
                            up = False
                        if self.api_callback:
                            self.api_callback("webapp_status", ip, up)

            # Sleep in 1-second increments so we can exit quickly
            for _ in range(30):
                if self._stop:
                    break
                time.sleep(1)

    # ------------------------------------------------------------------
    # Sweeper — removes stale devices
    # ------------------------------------------------------------------

    def _sweeper_loop(self) -> None:
        """Remove devices not seen for ``_stale_timeout`` seconds."""
        while not self._stop:
            now = time.time()
            to_delete: list[str] = []

            with self._registry_lock:
                for key, rec in list(self._registry.items()):
                    if now - rec["last_seen"] > self._stale_timeout:
                        for ip in rec["ips"]:
                            if self.api_callback:
                                self.api_callback("device_gone", ip)
                        to_delete.append(key)
                for key in to_delete:
                    self._registry.pop(key, None)

            for _ in range(5):
                if self._stop:
                    break
                time.sleep(1)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _ip_tag(ip: str) -> str:
        """Return a human-readable interface tag for the given IP."""
        if ip.startswith("172.20.2."):
            return "USB"
        if ip.startswith("172.20.1."):
            return "Bluetooth"
        return "LAN"

    @staticmethod
    def _normalize_host(host: Optional[str]) -> str:
        """Strip and lower-case a hostname, removing .local/.home suffixes."""
        if not host:
            return ""
        h = host.strip().lower().rstrip(".")
        if h.endswith(".local"):
            h = h[:-6]
        elif h.endswith(".home"):
            h = h[:-5]
        return h

    def _device_key(self, label: str, ip: str) -> str:
        """Compute a stable key for a device (hostname preferred, IP fallback)."""
        host = self._normalize_host(label or self._reverse_hostname(ip))
        if self._is_bjorn_hostname(host):
            return host
        return ip

    @staticmethod
    def _is_bjorn_hostname(host_or_fullname: str) -> bool:
        """Return ``True`` if *host_or_fullname* looks like a Bjorn device."""
        if not host_or_fullname:
            return False
        s = host_or_fullname.strip().lower().rstrip(".")
        if s in ("bjorn.local", "bjorn.home"):
            return True
        if s.startswith("bjorn") and (s.endswith(".local") or s.endswith(".home")):
            return True
        return s == "bjorn" or s.startswith("bjorn-") or s.startswith("bjorn_")

    @staticmethod
    def _reverse_hostname(ip: str) -> Optional[str]:
        """Attempt a reverse DNS lookup for *ip*."""
        try:
            host, _, _ = socket.gethostbyaddr(ip)
            return host.strip().lower()
        except Exception:
            return None

    @staticmethod
    def _get_gateway_cidr() -> Optional[ipaddress.IPv4Network]:
        """Return the /24 network of the default gateway, or ``None``."""
        try:
            gws = netifaces.gateways()
            default_gw = gws.get("default")
            if default_gw and netifaces.AF_INET in default_gw:
                _gw_ip, iface = default_gw[netifaces.AF_INET]
                addrs = netifaces.ifaddresses(iface).get(netifaces.AF_INET, [])
                if addrs:
                    ip = addrs[0]["addr"]
                    netmask = addrs[0]["netmask"]
                    return ipaddress.ip_network(f"{ip}/{netmask}", strict=False)
        except Exception:
            pass
        return None

    def _build_ignored_ips(self) -> None:
        """Populate the set of IPs that should never be reported as Bjorn devices.

        This includes gateway/router IPs and the machine's own addresses.
        """
        try:
            gws = netifaces.gateways()
            default_gw = gws.get("default")
            if default_gw and netifaces.AF_INET in default_gw:
                gw_ip, _ = default_gw[netifaces.AF_INET]
                self._ignored_ips.add(gw_ip)
            # Also add all non-default gateways
            for gw_list in gws.values():
                if isinstance(gw_list, list):
                    for entry in gw_list:
                        if isinstance(entry, tuple) and len(entry) >= 1:
                            self._ignored_ips.add(entry[0])
        except Exception:
            pass
        # Common router IPs that are never a Bjorn
        for common in ("192.168.1.1", "192.168.0.1", "192.168.1.254", "10.0.0.1"):
            self._ignored_ips.add(common)
        # Own IPs — this machine is not a Bjorn target
        try:
            for iface_name in netifaces.interfaces():
                addrs = netifaces.ifaddresses(iface_name).get(netifaces.AF_INET, [])
                for addr in addrs:
                    self._ignored_ips.add(addr.get("addr", ""))
        except Exception:
            pass

    def _is_ignored_ip(self, ip: str) -> bool:
        """Return True if *ip* should be silently skipped."""
        return ip in self._ignored_ips

    def _log(self, message: str, level: str = "info") -> None:
        """Print to stdout and forward to the API callback."""
        try:
            print(message, flush=True)
        except Exception:
            pass
        if self.api_callback:
            try:
                self.api_callback("log", message, level)
            except Exception:
                pass
