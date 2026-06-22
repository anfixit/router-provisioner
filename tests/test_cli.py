"""Tests for the command-line interface."""

from pathlib import Path

from typer.testing import CliRunner

from router_provisioner import __version__
from router_provisioner.cli import app

runner = CliRunner()


def test_version_option() -> None:
    """The CLI should print its version and exit successfully."""
    result = runner.invoke(app, ["--version"])

    assert result.exit_code == 0
    assert result.stdout.strip() == __version__


def test_cli_without_arguments_shows_help() -> None:
    """The CLI should show help when started without arguments."""
    result = runner.invoke(app)

    assert result.exit_code == 0
    assert "Cross-platform provisioning tool" in result.stdout


def test_validate_config_accepts_valid_profile(tmp_path: Path) -> None:
    """A valid profile should pass CLI validation."""
    config_path = tmp_path / "profile.yaml"
    config_path.write_text(
        """
schema_version: 1
router:
  hostname: test-router
  lan_ip: 192.168.10.1
  ssh_port: 2810
wifi:
  ssid_2g: Test_2G
  ssid_5g: Test_5G
  password: secure-password
amneziawg:
  config_file: ./secrets/awg.conf
""".strip(),
        encoding="utf-8",
    )

    result = runner.invoke(app, ["validate-config", str(config_path)])

    assert result.exit_code == 0
    assert "Configuration is valid." in result.stdout
    assert "test-router" in result.stdout
    assert "2810" in result.stdout


def test_validate_config_rejects_invalid_profile(tmp_path: Path) -> None:
    """An invalid profile should fail CLI validation."""
    config_path = tmp_path / "profile.yaml"
    config_path.write_text(
        """
schema_version: 1
router:
  hostname: test-router
  lan_ip: 192.168.10.1
wifi:
  ssid_2g: Test_2G
  ssid_5g: Test_5G
  password: short
amneziawg:
  config_file: ./secrets/awg.conf
""".strip(),
        encoding="utf-8",
    )

    result = runner.invoke(app, ["validate-config", str(config_path)])

    assert result.exit_code == 1
    assert "Configuration is invalid." in result.stdout
