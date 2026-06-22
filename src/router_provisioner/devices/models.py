"""Device profile models and loading."""

from pathlib import Path
from typing import Self

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError


class FirmwareFile(BaseModel):
    """Firmware artifact required by a device workflow."""

    model_config = ConfigDict(extra="forbid")

    role: str = Field(min_length=1)
    filename: str = Field(min_length=1)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class DeviceProfile(BaseModel):
    """Static description of a supported router model."""

    model_config = ConfigDict(extra="forbid")

    schema_version: int = Field(default=1, ge=1)
    device_id: str = Field(pattern=r"^[a-z0-9_]+$")
    vendor: str = Field(min_length=1)
    model: str = Field(min_length=1)
    hardware_version: str = Field(min_length=1)
    openwrt_board_names: list[str] = Field(min_length=1)
    supported_layouts: list[str] = Field(min_length=1)
    default_factory_ip: str = Field(min_length=1)
    default_openwrt_ip: str = Field(min_length=1)
    firmware: list[FirmwareFile] = Field(min_length=1)

    @classmethod
    def from_yaml(cls, path: Path) -> Self:
        """Load and validate a device profile from YAML."""
        try:
            raw_data = yaml.safe_load(path.read_text(encoding="utf-8"))
        except OSError as exc:
            raise DeviceProfileLoadError(
                f"Cannot read device profile: {path}"
            ) from exc
        except yaml.YAMLError as exc:
            raise DeviceProfileLoadError(
                f"Invalid YAML in device profile: {path}"
            ) from exc

        if not isinstance(raw_data, dict):
            raise DeviceProfileLoadError(
                "Device profile root must be a YAML mapping."
            )

        try:
            return cls.model_validate(raw_data)
        except ValidationError as exc:
            raise DeviceProfileLoadError(str(exc)) from exc


class DeviceProfileLoadError(ValueError):
    """Raised when a device profile cannot be loaded."""
