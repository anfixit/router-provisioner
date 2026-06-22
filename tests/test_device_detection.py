"""Tests for supported device profiles."""

from pathlib import Path

import pytest

from router_provisioner.devices.cudy_wbr3000uax_v1 import load_profile
from router_provisioner.devices.models import (
    DeviceProfile,
    DeviceProfileLoadError,
)


def test_load_cudy_wbr3000uax_profile() -> None:
    """The bundled Cudy device profile should be valid."""
    project_root = Path(__file__).resolve().parents[1]

    profile = load_profile(project_root)

    assert profile.device_id == "cudy_wbr3000uax_v1"
    assert "cudy,wbr3000uax-v1-ubootmod" in profile.openwrt_board_names
    assert profile.supported_layouts == ["factory", "ubootmod"]
    assert {item.role for item in profile.firmware} == {
        "preloader",
        "uboot",
        "recovery",
        "sysupgrade",
    }


def test_reject_invalid_firmware_checksum(tmp_path: Path) -> None:
    """Firmware checksums must contain exactly 64 hexadecimal characters."""
    profile_path = tmp_path / "device.yaml"
    profile_path.write_text(
        """
schema_version: 1
device_id: test_router
vendor: Test
model: Router
hardware_version: v1
openwrt_board_names:
  - test,router
supported_layouts:
  - factory
default_factory_ip: 192.168.1.1
default_openwrt_ip: 192.168.1.1
firmware:
  - role: sysupgrade
    filename: image.itb
    sha256: invalid
""".strip(),
        encoding="utf-8",
    )

    with pytest.raises(DeviceProfileLoadError):
        DeviceProfile.from_yaml(profile_path)


def test_reject_unknown_device_profile_fields(tmp_path: Path) -> None:
    """Unknown fields should not be silently ignored."""
    profile_path = tmp_path / "device.yaml"
    profile_path.write_text(
        """
schema_version: 1
device_id: test_router
vendor: Test
model: Router
hardware_version: v1
openwrt_board_names:
  - test,router
supported_layouts:
  - factory
default_factory_ip: 192.168.1.1
default_openwrt_ip: 192.168.1.1
unexpected: true
firmware:
  - role: sysupgrade
    filename: image.itb
    sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
""".strip(),
        encoding="utf-8",
    )

    with pytest.raises(DeviceProfileLoadError):
        DeviceProfile.from_yaml(profile_path)
