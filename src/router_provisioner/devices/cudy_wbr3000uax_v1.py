"""Cudy WBR3000UAX v1 device profile."""

from pathlib import Path

from router_provisioner.devices.models import DeviceProfile


DEVICE_ID = "cudy_wbr3000uax_v1"


def load_profile(project_root: Path) -> DeviceProfile:
    """Load the bundled Cudy WBR3000UAX v1 device profile."""
    profile_path = project_root / "devices" / DEVICE_ID / "device.yaml"
    return DeviceProfile.from_yaml(profile_path)
