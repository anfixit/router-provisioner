"""Command-line interface for Router Provisioner."""

from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.table import Table

from router_provisioner import __version__
from router_provisioner.config import ConfigLoadError, ProvisioningConfig

app = typer.Typer(
    name="router-provisioner",
    help="Cross-platform provisioning tool for OpenWrt routers.",
    invoke_without_command=True,
)
console = Console()


def version_callback(value: bool) -> None:
    """Print the application version and exit."""
    if value:
        typer.echo(__version__)
        raise typer.Exit


@app.callback()
def main(
    ctx: typer.Context,
    version: Annotated[
        bool,
        typer.Option(
            "--version",
            "-V",
            callback=version_callback,
            is_eager=True,
            help="Show the application version and exit.",
        ),
    ] = False,
) -> None:
    """Run Router Provisioner."""
    if ctx.invoked_subcommand is None and not version:
        typer.echo(ctx.get_help())


@app.command("validate-config")
def validate_config(
    config_path: Annotated[
        Path,
        typer.Argument(
            exists=True,
            dir_okay=False,
            readable=True,
            resolve_path=True,
            help="Path to a YAML provisioning profile.",
        ),
    ],
) -> None:
    """Validate a provisioning profile without changing a router."""
    try:
        config = ProvisioningConfig.from_yaml(config_path)
    except ConfigLoadError as exc:
        console.print("[bold red]Configuration is invalid.[/bold red]")
        console.print(str(exc))
        raise typer.Exit(code=1) from exc

    table = Table(title="Provisioning profile")
    table.add_column("Setting", style="cyan")
    table.add_column("Value")

    table.add_row("Schema version", str(config.schema_version))
    table.add_row("Hostname", config.router.hostname)
    table.add_row("LAN IP", config.router.lan_ip)
    table.add_row("SSH port", str(config.router.ssh_port))
    table.add_row("Wi-Fi 2.4 GHz", config.wifi.ssid_2g)
    table.add_row("Wi-Fi 5 GHz", config.wifi.ssid_5g)
    table.add_row("AmneziaWG config", str(config.amneziawg.config_file))

    console.print("[bold green]Configuration is valid.[/bold green]")
    console.print(table)
