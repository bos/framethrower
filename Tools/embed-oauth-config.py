#!/usr/bin/env python3
"""Bundle local OAuth application credentials without changing tracked files."""

import argparse
import os
from pathlib import Path
import plistlib
import shlex
import tempfile


ENV_KEYS = {
    "GDRIVE_CLIENT_ID": "GDriveClientID",
    "GDRIVE_CLIENT_SECRET": "GDriveClientSecret",
    "SLACK_CLIENT_ID": "SlackClientID",
    "SLACK_CLIENT_SECRET": "SlackClientSecret",
}


def read_env(path):
    """Read literal KEY=value assignments; never execute the file as a shell."""
    if not path.exists():
        return {}
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, separator, value = line.partition("=")
        key = key.strip()
        if key not in ENV_KEYS:
            continue
        if not separator or key in values:
            raise ValueError(f"Invalid or duplicate {key} on env line {number}")
        try:
            parts = shlex.split(value, comments=True)
        except ValueError:
            raise ValueError(f"Invalid quoting on env line {number}") from None
        if len(parts) > 1:
            raise ValueError(f"Quote values containing spaces on env line {number}")
        values[key] = parts[0] if parts else ""
    return values


def embed(env_path, output_path, environ):
    values = read_env(env_path)
    config = {
        plist_key: environ.get(env_key, values.get(env_key, ""))
        for env_key, plist_key in ENV_KEYS.items()
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    # Always replace the resource, including when .env was removed. This prevents
    # credentials from a previous incremental build leaking into a new build.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output_path.parent, delete=False) as out:
            temporary = Path(out.name)
            plistlib.dump(config, out)
        os.replace(temporary, output_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        embed(args.env, args.output, os.environ)
    except (OSError, ValueError) as error:
        # Parsing errors identify the line/key, never the credential value.
        parser.exit(1, f"OAuth configuration: {error}\n")


if __name__ == "__main__":
    main()
