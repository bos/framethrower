#!/bin/sh
# Read-only inspection of an already-built, signed app. No build, launch,
# microphone, model inference, playback, or media operations.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${1:-"$repo_dir/build/Build/Products/Debug/FrameThrower.app"}
python3 - "$app" <<'PY'
from pathlib import Path
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    require(result.returncode == 0, f"{' '.join(arguments)} failed:\n{(result.stdout + result.stderr)[-6000:]}")
    return result.stdout + result.stderr


def inside(path, directory):
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


try:
    app = Path(sys.argv[1]).resolve(strict=True)
    require(app.is_dir() and app.suffix == '.app', f"Not an application bundle: {app}")
    helpers = app / 'Contents/Helpers/LocalSpeech'
    require(helpers.is_dir() and not helpers.is_symlink(), 'Missing local speech helper directory')
    helpers = helpers.resolve(strict=True)
    helper = helpers / 'FrameThrowerSpeech'
    require(helper.is_file() and not helper.is_symlink(), 'Missing regular FrameThrowerSpeech executable')
    require(helper.stat().st_mode & 0o111, 'Speech helper is not executable')
    license_file = app / 'Contents/Resources/LocalSpeech-LICENSE.txt'
    require(license_file.is_file() and license_file.stat().st_size > 0, 'Missing nonempty speech license in Contents/Resources')
    require(inside(license_file.resolve(strict=True), (app / 'Contents/Resources').resolve(strict=True)), 'Speech license escapes Resources')
    for name in ['whisper', 'ggml', 'ggml-base', 'ggml-cpu', 'ggml-blas', 'ggml-metal']:
        require((helpers / f'lib{name}.dylib').is_file(), f'Missing bundled lib{name}.dylib')

    magic_values = {bytes.fromhex(value) for value in ['cffaedfe', 'cefaedfe', 'feedfacf', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}
    code = []
    for entry in sorted(helpers.iterdir()):
        require(entry.name == 'FrameThrowerSpeech' or re.fullmatch(r'lib[^/]+\.dylib', entry.name), f'Non-code file in nested Helpers: {entry.name}')
        if entry.is_symlink():
            target = entry.readlink()
            require(not target.is_absolute(), f'Absolute dylib symlink: {entry.name}')
            resolved = entry.resolve(strict=True)
            require(inside(resolved, helpers) and resolved.is_file(), f'Dylib symlink escapes helper bundle: {entry.name}')
            continue
        require(entry.is_file(), f'Unexpected directory or special file in nested Helpers: {entry.name}')
        with entry.open('rb') as source:
            require(source.read(4) in magic_values, f'Non-Mach-O file in nested Helpers: {entry.name}')
        code.append(entry)

    # Validate the outer seal as well as every actual nested code object.
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    identities = {}
    for item in [app] + code:
        run('/usr/bin/codesign', '--verify', '--strict', str(item))
        details = run('/usr/bin/codesign', '--display', '--verbose=4', str(item))
        match = re.search(r'^TeamIdentifier=(.+)$', details, re.M)
        identities[item.name] = match.group(1).strip() if match and match.group(1).strip() != 'not set' else None
    teams = {identity for identity in identities.values() if identity is not None}
    require(len(teams) <= 1, f'Mismatched nested signing Team IDs: {identities}')
    if teams:
        require(all(identity in teams for identity in identities.values()), f'Ad-hoc code mixed into developer-signed app: {identities}')

    for item in code:
        load_commands = run('/usr/bin/otool', '-l', str(item))
        rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)', load_commands)
        if item == helper:
            require('@loader_path' in rpaths, 'Speech helper lacks portable @loader_path RPATH')
        for rpath in rpaths:
            require(rpath == '@loader_path' or rpath.startswith('@loader_path/'), f'Nonportable RPATH in {item.name}: {rpath}')
            suffix = rpath[len('@loader_path'):].lstrip('/')
            require(inside((item.parent / suffix).resolve(), helpers), f'RPATH escapes helper bundle in {item.name}: {rpath}')
        dependencies = run('/usr/bin/otool', '-L', str(item))
        for dependency in re.findall(r'^\s+(.+?) \(compatibility version ', dependencies, re.M):
            if dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            if dependency.startswith('@rpath/'):
                target = helpers / dependency[len('@rpath/'):]
            elif dependency.startswith('@loader_path/'):
                target = item.parent / dependency[len('@loader_path/'):]
            else:
                raise RuntimeError(f'Nonportable library dependency in {item.name}: {dependency}')
            resolved = target.resolve(strict=True)
            require(inside(resolved, helpers) and resolved.is_file(), f'Unbundled dependency in {item.name}: {dependency}')
    team = next(iter(teams), 'ad-hoc')
    print(f'PASS: signed outer app, {len(code)} nested speech code objects, Team ID {team}, Resources license, internal dylib symlinks, portable loader paths (read-only; no launch/inference/media)')
except (OSError, RuntimeError) as error:
    print(f'FAIL: {error}', file=sys.stderr)
    sys.exit(1)
PY
