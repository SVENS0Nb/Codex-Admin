#!/usr/bin/env python3
"""Run one SSH command with strict host-key checking and no secret arguments."""

from __future__ import annotations

import argparse
from pathlib import Path
import shlex
import sys

import paramiko


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", required=True)
    command = parser.add_mutually_exclusive_group(required=True)
    command.add_argument("--command")
    command.add_argument(
        "--script-stdin",
        action="store_true",
        help="Read a remote POSIX shell script from standard input and execute it through /bin/sh -s.",
    )
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument(
        "--known-hosts",
        type=Path,
        default=Path.home() / ".ssh" / "known_hosts",
    )
    parser.add_argument("--identity", type=Path)
    parser.add_argument(
        "--password-stdin",
        action="store_true",
        help="Read the SSH password from standard input.",
    )
    parser.add_argument(
        "--sudo-password-stdin",
        action="store_true",
        help="Use the standard-input secret for sudo as well as optional SSH authentication.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.known_hosts.is_file():
        raise SystemExit(f"Known-hosts file not found: {args.known_hosts}")

    password = None
    sudo_password = None
    script = None
    if args.script_stdin and (args.password_stdin or args.sudo_password_stdin):
        raise SystemExit("Command and password cannot both be read from standard input.")

    if args.script_stdin:
        script = sys.stdin.read()
        if not script or not script.strip():
            raise SystemExit("No remote script received.")

    if args.password_stdin or args.sudo_password_stdin:
        secret = sys.stdin.readline().rstrip("\r\n")
        if not secret:
            raise SystemExit("No password received on standard input.")
        if args.password_stdin:
            password = secret
        if args.sudo_password_stdin:
            sudo_password = secret
        secret = None

    client = paramiko.SSHClient()
    client.load_host_keys(str(args.known_hosts))
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    try:
        client.connect(
            hostname=args.host,
            port=args.port,
            username=args.user,
            password=password,
            key_filename=str(args.identity) if args.identity else None,
            allow_agent=False,
            look_for_keys=False,
            timeout=10,
            auth_timeout=10,
            banner_timeout=10,
        )
        command = "/bin/sh -s" if script is not None else args.command
        if sudo_password is not None:
            command = (
                "sudo -S -p '' -k /bin/sh -c "
                + shlex.quote(args.command)
            )
        stdin, stdout, stderr = client.exec_command(command, timeout=60)
        if script is not None:
            stdin.write(script)
            stdin.flush()
            stdin.channel.shutdown_write()
        elif sudo_password is not None:
            stdin.write(sudo_password + "\n")
            stdin.flush()
            stdin.channel.shutdown_write()
        out = stdout.read()
        err = stderr.read()
        if out:
            sys.stdout.buffer.write(out)
        if err:
            sys.stderr.buffer.write(err)
        return stdout.channel.recv_exit_status()
    finally:
        password = None
        sudo_password = None
        script = None
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
