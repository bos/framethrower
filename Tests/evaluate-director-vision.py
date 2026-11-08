#!/usr/bin/env python3
"""Opt-in cloud image transport check; static synthetic PNGs, no media APIs.
Run only after the text cohort finishes so requests never overlap local inference.
This checks attachment/region understanding, not real-footage editing accuracy.
"""
import argparse, base64, hashlib, importlib.util, json, pathlib, struct, time, zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROFILES = [('claude', 'claude-haiku-5-5', 'low'), ('claude', 'claude-sonnet-5-5', 'medium'),
            ('codex', 'gpt-6-luna', 'medium'), ('codex', 'gpt-6.1-sol', 'medium')]


def fixture():
    width, height = 1000, 600
    pixels = bytearray(bytes([245, 245, 245]) * width * height)
    for bounds, color in [((750, 180, 930, 380), (150, 150, 150)),
                          ((200, 120, 700, 420), (40, 100, 210))]:
        left, top, right, bottom = bounds
        for y in range(top, bottom):
            start = 3 * (y * width + left)
            pixels[start:start + 3 * (right - left)] = bytes(color) * (right - left)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    raw = b''.join(b'\0' + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    return png + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def payload(png):
    rect = {'type': 'object', 'properties': {key: {'type': 'number', 'minimum': 0, 'maximum': 1}
                                          for key in ['x', 'y', 'width', 'height']},
            'required': ['x', 'y', 'width', 'height'], 'additionalProperties': False}
    return {'messages': [
        {'role': 'system', 'content': 'Inspect only the attached synthetic frame. Return the blue rectangle bounds using the offered tool. The application calculates borders; do not add padding.'},
        {'role': 'user', 'content': [
            {'type': 'text', 'text': 'Synthetic fixture, frame_id=vision-fixture, source_time=2, source_width=1000, source_height=600. Zoom into the blue window with a 30 pixel border. First identify its unpadded bounds in normalized original-image coordinates.'},
            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(png).decode(), 'detail': 'high'}}]}],
        'tools': [{'type': 'function', 'function': {'name': 'locate_target', 'description': 'Return the visible target bounds; never infer them from a filename or current desktop.',
                                                 'parameters': rect}}]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='Explicitly call the four signed-in cloud CLI profiles')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'build/DirectorProviderEvaluation/vision-smoke')
    options = parser.parse_args()
    png = fixture(); request = payload(png)
    options.output.mkdir(parents=True, exist_ok=True)
    (options.output / 'synthetic-window.png').write_bytes(png)
    (options.output / 'fixture.json').write_text(json.dumps({'image_sha256': hashlib.sha256(png).hexdigest(),
        'width': 1000, 'height': 600, 'expected_normalized_rect': {'x': .2, 'y': .2, 'width': .5, 'height': .5},
        'tolerance_source_pixels': 10, 'purpose': 'Synthetic attachment/region smoke only; no video/real desktop/footage'}, indent=2))
    if not options.run:
        print('Fixture generated; no model calls. Pass --run for sequential cloud image checks.'); return
    spec = importlib.util.spec_from_file_location('director_bridge', ROOT / 'Tools/director-cli-client.py')
    bridge = importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)
    results = []
    for provider, model, effort in PROFILES:
        started = time.monotonic()
        entry = {'provider': provider, 'model': model, 'effort': effort}
        try:
            response = bridge.invoke(provider, model, json.dumps(request), effort=effort, timeout=90)
            arguments = json.loads(response['choices'][0]['message']['tool_calls'][0]['function']['arguments'])
            expected = {'x': .2, 'y': .2, 'width': .5, 'height': .5}
            errors = {key: abs(arguments[key] - expected[key]) * (1000 if key in ('x', 'width') else 600) for key in expected}
            entry.update(response=response, source_pixel_errors=errors, passed=all(value <= 10 for value in errors.values()))
        except Exception as error:
            entry.update(passed=False, error=str(error))
        entry['wall_seconds'] = time.monotonic() - started
        results.append(entry)
        (options.output / 'results.json').write_text(json.dumps(results, indent=2))
        print(json.dumps({key: value for key, value in entry.items() if key != 'response'}), flush=True)


if __name__ == '__main__': main()
