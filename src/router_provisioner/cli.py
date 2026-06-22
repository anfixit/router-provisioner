"""Command-line interface for Router Provisioner."""

from typing import Annotated

import typer

from router_provisioner import __version__

app = typer.Typer(
    name="router-provisioner",
    help="Cross-platform provisioning tool for OpenWrt routers.",
    invoke_without_command=True,
)


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
