"""Abstract base class for platform-specific installation logic."""

from abc import ABC, abstractmethod


class PlatformInstaller(ABC):
    """Abstract base for platform-specific installation logic.

    Subclasses implement platform-aware package lists, system configuration
    options, and feature support queries.  Planned implementations include
    RaspberryPiInstaller, DebianInstaller, and WindowsInstaller.
    """

    @abstractmethod
    def get_package_list(self) -> dict:
        """Return a dict with ``'apt'`` and ``'pip'`` package lists.

        Example return value::

            {
                "apt": ["git", "python3-pip", ...],
                "pip": ["paramiko", "spidev", ...],
            }
        """
        ...

    @abstractmethod
    def get_system_configs(self) -> list:
        """Return a list of system configuration option descriptors.

        Each entry is a dict describing a toggleable system configuration
        (e.g. SPI, I2C, Bluetooth, USB gadget).
        """
        ...

    @abstractmethod
    def supports_feature(self, feature: str) -> bool:
        """Check whether *feature* is supported on this platform.

        Common feature identifiers: ``spi``, ``i2c``, ``bluetooth``,
        ``usb_gadget``, ``wifi``, ``systemd``.
        """
        ...
