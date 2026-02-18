from dataclasses import dataclass
from typing import Optional


@dataclass
class SSHConfig:
    host: str
    port: int
    user: str
    password: Optional[str] = None
    key_path: Optional[str] = None
    sudo_password: Optional[str] = None
