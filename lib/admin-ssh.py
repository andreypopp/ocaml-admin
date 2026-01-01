#!/usr/bin/env -S uv run --no-progress --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "click",
#     "parallel-ssh",
#     "rich",
# ]
# ///
"""Run SSH commands on multiple hosts in parallel.

Input (stdin):
    {
        "<hostname>": {
            "username": <string|null>,
            "tasks": [
                {
                    "type": "command",
                    "command": <string>,
                    "desc": <string|null>,
                    "use_sudo": <bool>
                },
                {
                    "type": "upload",
                    "local": <string>,
                    "remote": <string>,
                    "use_sudo": <bool>,
                    "chmod": <octal mode as string, same as chmod>,
                    "chown": <user:group>
                },
                {
                    "type": "upload-content",
                    "content": <string>,
                    "remote": <string>,
                    "use_sudo": <bool>,
                    "chmod": <octal mode as string, same as chmod>,
                    "chown": <user:group>
                }, ...
            ]
        }, ...
    }

Output (stdout):
    {
        "<hostname>": {
            "commands": {
                "<cmd>": {"exit_code": <int>, "stdout": [<str>], "stderr": [<str>]}
            },
            "uploads": [
                {
                    "local": <string|null>,
                    "remote": <string>,
                    "status": <"done"|"error">,
                    "error": <string|null>
                }, ...
            ]
        }
    }

Progress is displayed on stderr.
"""

from __future__ import annotations

import json
import os
import shlex
import sys
import time
import uuid
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass, field

import click
import gevent
import ssh2.exceptions
from gevent.pool import Pool
from pssh.clients import ParallelSSHClient
from rich.console import Console
from rich.live import Live
from rich.table import Table


@dataclass
class CommandState:
    """State for a single command execution."""

    cmd: str
    desc: str | None
    use_sudo: bool
    status: str = "pending"  # pending | running | done | error
    exit_code: int | None = None
    stdout: list[str] = field(default_factory=list)
    stderr: list[str] = field(default_factory=list)
    error: str | None = None
    start_time: float | None = None
    end_time: float | None = None


@dataclass
class OfPath:
    path: str

    @contextmanager
    def using(self):
        yield self.path


@dataclass
class OfContent:
    content: str

    @contextmanager
    def using(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as tmp:
            tmp.write(self.content)
            tmp.flush()
            yield tmp.name


@dataclass
class UploadState:
    """State for a single file upload."""

    local: OfPath | OfContent
    remote: str
    use_sudo: bool
    chmod: str | None
    chown: str | None
    status: str = "pending"  # pending | running | done | error
    error: str | None = None
    start_time: float | None = None
    end_time: float | None = None


@dataclass
class HostState:
    """State for a single host."""

    tasks: list[CommandState | UploadState] = field(default_factory=list)
    start_time: float | None = None
    end_time: float | None = None


def format_timing(state: HostState | CommandState | UploadState) -> str:
    if state.start_time is None:
        elapsed = 0.0
        return f"[yellow]{elapsed:.2f}s[/yellow]"
    elif state.end_time is not None:
        elapsed = state.end_time - state.start_time
        if isinstance(state, (CommandState, UploadState)) and state.status == "error":
            return f"[red]{elapsed:.2f}s[/red]"
        else:
            return f"[green]{elapsed:.2f}s[/green]"
    else:
        elapsed = time.time() - state.start_time
        return f"[yellow]{elapsed:.2f}s[/yellow]"


def build_table(state: dict[str, HostState]) -> Table:
    """Build a minimal table showing host progress."""
    task_max_width = 40
    table = Table(box=None, show_header=False)
    table.add_column(
        "task", min_width=task_max_width, max_width=task_max_width, no_wrap=True
    )
    table.add_column("time", justify="right")
    table.add_column("progress", justify="right")

    for host, host_state in state.items():
        running = sum(1 for c in host_state.tasks if c.status == "running")
        errors = sum(1 for c in host_state.tasks if c.status == "error")
        done = sum(1 for c in host_state.tasks if c.status == "done")
        total = len(host_state.tasks)

        # Build "# running + # errors + # done / # total"
        parts = []
        if done == total:
            progress = f"[green]{done}/{total}[/green]"
        else:
            if running > 0:
                parts.append(f"[yellow]{running}[/yellow]")
            if errors > 0:
                parts.append(f"[red]{errors}[/red]")
            if done > 0:
                parts.append(f"[green]{done}[/green]")
            if not parts:
                parts.append("0")
            progress = f"{'+'.join(parts)}/{total}"

        table.add_row(f"[bold]{host}[/bold]", format_timing(host_state), progress)

        for task in host_state.tasks:
            if task.status in {"pending", "done"}:
                continue
            if host_state.end_time is not None and task.status not in {"error"}:
                continue
            if isinstance(task, CommandState):
                desc = task.desc or task.cmd
            elif isinstance(task, UploadState):
                desc = f"upload {task.remote}"
            status = task.status
            if status == "done":
                status_str = f" [green]{desc}[/green]"
            elif status == "running":
                status_str = f" [yellow]{desc}[/yellow]"
            elif status == "error":
                status_str = f" [red]{desc}[/red]"
            table.add_row(status_str, format_timing(task), "")

    return table


def build_state(plan: dict[str, dict]) -> dict[str, HostState]:
    """Build initial state from input JSON."""
    state: dict[str, HostState] = {}
    for hostname, host_data in plan.items():
        tasks: list[CommandState | UploadState] = []
        for task in host_data.get("tasks", []):
            if task["type"] == "command":
                tasks.append(
                    CommandState(
                        cmd=task["command"],
                        desc=task.get("desc"),
                        use_sudo=task.get("use_sudo", False),
                    )
                )
            elif task["type"] == "upload":
                tasks.append(
                    UploadState(
                        local=OfPath(task["local"]),
                        remote=task["remote"],
                        use_sudo=task.get("use_sudo", False),
                        chmod=task.get("chmod"),
                        chown=task.get("chown"),
                    )
                )
            elif task["type"] == "upload-content":
                tasks.append(
                    UploadState(
                        local=OfContent(task["content"]),
                        remote=task["remote"],
                        use_sudo=task.get("use_sudo", False),
                        chmod=task.get("chmod"),
                        chown=task.get("chown"),
                    )
                )
        state[hostname] = HostState(tasks=tasks)
    return state


def report_failure(
    console: Console, host: str, task: CommandState | UploadState
) -> None:
    """Print failure details to stderr immediately."""
    if isinstance(task, CommandState):
        console.print(
            f" [bold red]error at {host} (exited: {task.exit_code})[/bold red]"
        )
        for line in task.cmd.split("\n"):
            console.print(f"   [red]{line}[/red]")
        if task.stdout:
            console.print(" [red]stdout:[/red]")
            for line in task.stdout:
                console.print(f"   [red]{line}[/red]")
        if task.stderr:
            console.print(" [red]stderr:[/red]")
            for line in task.stderr:
                console.print(f"   [red]{line}[/red]")
    elif isinstance(task, UploadState):
        console.print(f" [bold red]at {host}[/bold red] [dim](upload failed)[/dim]")
        console.print(f"   [red]{task.remote}[/red]")
        if task.error:
            console.print(" [red]error:[/red]")
            for line in task.error.split("\n"):
                console.print(f"   [red]{line}[/red]")
    console.print("")


def build_results(state: dict[str, HostState]) -> dict[str, dict]:
    """Build output JSON from state (commands and uploads)."""
    results: dict[str, dict] = {}

    for host, host_state in state.items():
        commands = {}
        uploads = []
        for task in host_state.tasks:
            if isinstance(task, CommandState):
                commands[task.cmd] = {
                    "exit_code": task.exit_code,
                    "stdout": task.stdout,
                    "stderr": task.stderr,
                }
                if task.error:
                    commands[task.cmd]["error"] = task.error
            elif isinstance(task, UploadState):
                uploads.append(
                    {
                        "remote": task.remote,
                        "status": task.status,
                        "error": task.error,
                    }
                )

        results[host] = {"commands": commands, "uploads": uploads}

    return results


def run_command(client: ParallelSSHClient, cmd_state: CommandState) -> None:
    """Greenlet: run a single command and collect its output."""
    cmd_state.status = "running"
    cmd_state.start_time = time.time()
    cmd = f"bash -eu -o pipefail -c {shlex.quote(cmd_state.cmd)}"
    if cmd_state.use_sudo:
        cmd = f"sudo {cmd}"
    for _ in range(5):
        try:
            output = client.run_command(cmd)[0]
            cmd_state.stdout = list(output.stdout) if output.stdout else []
            cmd_state.stderr = list(output.stderr) if output.stderr else []
            cmd_state.exit_code = output.exit_code
            cmd_state.status = "done"
            cmd_state.end_time = time.time()
        except ssh2.exceptions.SSH2Error:
            time.sleep(0.1)
            continue
        except Exception as e:
            cmd_state.status = "error"
            cmd_state.error = str(e)
            cmd_state.end_time = time.time()
        else:
            break


def run_upload(client: ParallelSSHClient, upload_state: UploadState) -> None:
    """Greenlet: upload a single file and optionally set chmod."""
    upload_state.status = "running"
    upload_state.start_time = time.time()
    try:
        # Copy to temp location in same dir, then mv to target
        temp_path = f"/home/andreypopp/.tmp.{uuid.uuid4().hex}"
        with upload_state.local.using() as local_path:
            greenlets = client.copy_file(local_path, temp_path)
            gevent.joinall(greenlets, raise_error=True)

        # Move to final location with sudo
        output = client.run_command(
            f"mv {temp_path} {upload_state.remote}",
            sudo=upload_state.use_sudo,
            shell="bash -c",
        )[0]
        stdout = list(output.stdout) if output.stdout else []
        stderr = list(output.stderr) if output.stderr else []
        if output.exit_code != 0:
            raise Exception(
                f"mv failed:\nstderr:\n{' '.join(stderr)}\nstdout:\n{''.join(stdout)}"
            )

        # Set chmod if specified
        if upload_state.chmod:
            output = client.run_command(
                f"chmod {upload_state.chmod} {upload_state.remote}",
                sudo=upload_state.use_sudo,
                shell="bash -c",
            )[0]
            stdout = list(output.stdout) if output.stdout else []
            stderr = list(output.stderr) if output.stderr else []
            if output.exit_code != 0:
                raise Exception(
                    f"chmod failed:\nstderr:\n{' '.join(stderr)}\nstdout:\n{''.join(stdout)}"
                )

        # Set chown if specified
        if upload_state.chown:
            output = client.run_command(
                f"chown {upload_state.chown} {upload_state.remote}",
                sudo=upload_state.use_sudo,
                shell="bash -c",
            )[0]
            stdout = list(output.stdout) if output.stdout else []
            stderr = list(output.stderr) if output.stderr else []
            if output.exit_code != 0:
                raise Exception(
                    f"chown failed:\nstderr:\n{' '.join(stderr)}\nstdout:\n{''.join(stdout)}"
                )

        upload_state.status = "done"
        upload_state.end_time = time.time()
    except Exception as e:
        upload_state.status = "error"
        upload_state.error = str(e)
        upload_state.end_time = time.time()


def run_host(
    host: str,
    username: str | None,
    host_state: HostState,
    par_per_host: int,
    serial: bool,
    console: Console,
):
    """Runs all commands and uploads on one host."""
    host_state.start_time = time.time()
    try:
        client = ParallelSSHClient([host], user=username)
        if serial:
            for task in host_state.tasks:
                if isinstance(task, CommandState):
                    run_command(client, task)
                elif isinstance(task, UploadState):
                    run_upload(client, task)
                if (
                    isinstance(task, CommandState)
                    and task.exit_code is not None
                    and task.exit_code != 0
                ):
                    task.status = "error"
                if task.status == "error":
                    report_failure(console, host, task)
                    break
        else:
            pool = Pool(size=par_per_host)
            for task in host_state.tasks:
                if isinstance(task, CommandState):
                    pool.spawn(run_command, client, task)
                elif isinstance(task, UploadState):
                    pool.spawn(run_upload, client, task)
            pool.join()
    finally:
        host_state.end_time = time.time()


@click.command()
@click.option("--par", default=10, help="Max number of hosts to process in parallel.")
@click.option("--par-per-host", default=5, help="Max commands per host in parallel.")
@click.option(
    "--serial", is_flag=True, help="Execute tasks one by one, stop on first error."
)
@click.option("--quiet", is_flag=True, help="Suppress progress display.")
def main(par: int, par_per_host: int, serial: bool, quiet: bool) -> None:
    """Run commands on multiple hosts via SSH in parallel."""
    plan = json.load(sys.stdin)
    state = build_state(plan)

    if not state:
        print(json.dumps({}))
        return

    if quiet:
        # In quiet mode, create a simple stderr console for error reporting
        error_console = Console(stderr=True)
        pool = Pool(size=par)
        for hostname, host_data in plan.items():
            username = host_data.get("username")
            pool.spawn(
                run_host,
                hostname,
                username,
                state[hostname],
                par_per_host,
                serial,
                error_console,
            )
        pool.join()
    else:
        # With progress display, use live.console for error reporting
        console = Console(stderr=True)
        with Live(build_table(state), console=console, refresh_per_second=4) as live:
            pool = Pool(size=par)
            for hostname, host_data in plan.items():
                username = host_data.get("username")
                pool.spawn(
                    run_host,
                    hostname,
                    username,
                    state[hostname],
                    par_per_host,
                    serial,
                    live.console,
                )
            while not pool.join(timeout=0.1):
                live.update(build_table(state))
            live.update(build_table(state))

    results = build_results(state)
    print(json.dumps(results))


if __name__ == "__main__":
    main()
