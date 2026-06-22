"""Tests for the command-line interface."""

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
