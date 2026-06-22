"""Application configuration models and YAML loading."""

from pathlib import Path
from typing import Self

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError


class RouterConfig(BaseModel):
    """Router provisioning configuration."""

    model_config = ConfigDict(extra="forbid")

    hostname: str = Field(min_length=1)
    lan_ip: str = Field(min_length=1)
    ssh_port: int = Field(default=22, ge=1, le=65535)


class WifiConfig(BaseModel):
    """Wi-Fi configuration."""

    model_config = ConfigDict(extra="forbid")

    ssid_2g: str = Field(min_length=1)
    ssid_5g: str = Field(min_length=1)
    password: str = Field(min_length=8)


class AmneziaWireGuardConfig(BaseModel):
    """AmneziaWG configuration source."""

    model_config = ConfigDict(extra="forbid")

    config_file: Path


class ProvisioningConfig(BaseModel):
    """Complete provisioning profile."""

    model_config = ConfigDict(extra="forbid")

    schema_version: int = Field(default=1, ge=1)
    router: RouterConfig
    wifi: WifiConfig
    amneziawg: AmneziaWireGuardConfig

    @classmethod
    def from_yaml(cls, path: Path) -> Self:
        """Load and validate a provisioning profile from YAML."""
        try:
            raw_data = yaml.safe_load(path.read_text(encoding="utf-8"))
        except OSError as exc:
            raise ConfigLoadError(
                f"Cannot read configuration file: {path}"
            ) from exc
        except yaml.YAMLError as exc:
            raise ConfigLoadError(
                f"Invalid YAML in configuration file: {path}"
            ) from exc

        if not isinstance(raw_data, dict):
            raise ConfigLoadError("Configuration root must be a YAML mapping.")

        try:
            config = cls.model_validate(raw_data)
        except ValidationError as exc:
            raise ConfigLoadError(str(exc)) from exc

        config.amneziawg.config_file = (
            path.parent / config.amneziawg.config_file
        ).resolve()
        return config


class ConfigLoadError(ValueError):
    """Raised when a provisioning profile cannot be loaded."""
