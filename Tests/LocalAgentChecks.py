#!/usr/bin/env python3
"""Exercise a proposed editing-tool contract using a local text model.

This is a prototype contract check, not a FrameThrower RPC integration. It uses
fictional region metadata; it never opens recordings, starts capture, or applies
edits. Raw prompts and responses are saved locally and never printed.
"""
from __future__ import annotations

import argparse
import copy
import json
import math
import os
from pathlib import Path
import sys
import time
from typing import Any, Callable

PROJECT = "synthetic-demo"
REVISION = 7
SYSTEM = """You are testing a video editor's proposed tool interface.
Use exactly one appropriate tool when a supported action is requested. Return
only a tool call for such requests. The editor context is authoritative: use its
project ID, revision, region IDs, and selected edit ID. 'This area' means the
selected region. Do not guess when multiple regions match and none is selected;
ask one clarifying question using ask_clarification. A region label is an editing
note, not a request to alter the video. Revising an existing edit must use
revise_framing rather than creating another sequence. Sequence start_seconds is
when movement starts. Each step moves for move_seconds, then holds for
hold_seconds, before the next step begins. full_frame means the entire source.
For a capability marked unavailable, explain that briefly without making a tool
call. Do not invent tools or imply that a tool has already executed.
"""


def function(name: str, description: str, properties: dict[str, Any]) -> dict[str, Any]:
    return {"type": "function", "function": {
        "name": name, "description": description,
        "parameters": {"type": "object", "properties": properties,
                       "required": list(properties), "additionalProperties": False},
    }}


SCOPE = {
    "project_id": {"type": "string", "description": "The context's project ID."},
    "expected_revision": {"type": "integer", "description": "The context's current revision."},
}
TOOLS = [
    function("plan_sequence", "Describe a new framing sequence using known region IDs. This prototype returns a plan; it does not apply edits.", {
        **SCOPE,
        "start_seconds": {"type": "number", "minimum": 0},
        "steps": {"type": "array", "minItems": 1, "maxItems": 8, "items": {
            "type": "object", "properties": {
                "region_id": {"type": "string", "description": "An existing region ID or full_frame."},
                "move_seconds": {"type": "number", "minimum": 0.01},
                "hold_seconds": {"type": "number", "minimum": 0},
            }, "required": ["region_id", "move_seconds", "hold_seconds"],
            "additionalProperties": False,
        }},
    }),
    function("label_region", "Attach a descriptive note to a known scribble region, without changing framing or creating video edits.", {
        **SCOPE,
        "region_id": {"type": "string"},
        "label": {"type": "string"},
    }),
    function("revise_framing", "Change an existing edit's target region while preserving its timeline time and movement duration.", {
        **SCOPE,
        "edit_id": {"type": "string"},
        "region_id": {"type": "string"},
    }),
    function("ask_clarification", "Ask one short question when a requested target cannot be identified unambiguously from context.", {
        "question": {"type": "string"},
    }),
]


def context() -> dict[str, Any]:
    return {
        "project_id": PROJECT, "revision": REVISION, "duration_seconds": 12,
        "playhead_seconds": 3, "selected_region_id": "A",
        "regions": [
            {"id": "A", "label": "settings dialog", "frame_seconds": 3,
             "source_rect": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4}},
            {"id": "B", "label": "activity chart", "frame_seconds": 3,
             "source_rect": {"x": 0.6, "y": 0.2, "width": 0.3, "height": 0.4}},
        ],
        "selected_edit": {"id": "edit-7", "time_seconds": 3, "move_seconds": 0.8,
                          "region_id": "A"},
        "capabilities": {"plan_framing": True, "label_regions": True,
                         "revise_framing": True, "render_or_export_video": False},
        "video_status": "Video processing is temporarily disabled.",
    }


def finite_number(value: Any) -> float:
    assert type(value) in (int, float) and math.isfinite(value), "invalid numeric argument"
    return float(value)


def only_call(response: dict[str, Any], name: str) -> dict[str, Any]:
    choices = response.get("choices")
    assert isinstance(choices, list) and len(choices) == 1, "expected one completion choice"
    message = choices[0].get("message", {})
    calls = message.get("tool_calls", [])
    assert isinstance(calls, list) and len(calls) == 1, "expected exactly one tool call"
    call = calls[0]
    assert call.get("type") == "function", "expected a function tool call"
    fn = call.get("function", {})
    assert fn.get("name") == name, "incorrect tool selected"
    assert isinstance(fn.get("arguments"), str), "tool arguments must be JSON text"
    arguments = json.loads(fn["arguments"])
    assert isinstance(arguments, dict), "arguments must be an object"
    definition = next(tool["function"] for tool in TOOLS if tool["function"]["name"] == name)
    assert set(arguments) == set(definition["parameters"]["properties"]), "unexpected or missing arguments"
    if name != "ask_clarification":
        assert arguments["project_id"] == PROJECT, "incorrect project scope"
        assert type(arguments["expected_revision"]) is int and arguments["expected_revision"] == REVISION, "incorrect revision"
    return arguments


def check_sequence(response: dict[str, Any], start: float, expected: list[tuple[str, float, float]]) -> None:
    args = only_call(response, "plan_sequence")
    assert abs(finite_number(args["start_seconds"]) - start) < 1e-6, "incorrect sequence start"
    steps = args["steps"]
    assert isinstance(steps, list) and len(steps) == len(expected), "incorrect step count"
    cursor = start
    for step, (region, move, hold) in zip(steps, expected):
        assert isinstance(step, dict) and set(step) == {"region_id", "move_seconds", "hold_seconds"}, "invalid step shape"
        assert step["region_id"] == region, "incorrect target region"
        actual_move = finite_number(step["move_seconds"])
        actual_hold = finite_number(step["hold_seconds"])
        assert actual_move > 0 and actual_hold >= 0, "invalid movement or hold duration"
        assert abs(actual_move - move) < 1e-6 and abs(actual_hold - hold) < 1e-6, "incorrect movement/hold timing"
        cursor += actual_move + actual_hold
    assert cursor <= 12, "sequence exceeds recording duration"


def check_label(response: dict[str, Any]) -> None:
    args = only_call(response, "label_region")
    assert args["region_id"] == "A" and args["label"] == "account settings", "incorrect scribble note"


def check_revision(response: dict[str, Any]) -> None:
    args = only_call(response, "revise_framing")
    assert args["edit_id"] == "edit-7" and args["region_id"] == "B", "existing selected edit was not revised"


def check_ambiguity(response: dict[str, Any]) -> None:
    args = only_call(response, "ask_clarification")
    assert isinstance(args["question"], str) and 0 < len(args["question"].strip()) <= 400, "missing concise clarification"


def check_unavailable(response: dict[str, Any]) -> None:
    message = response.get("choices", [{}])[0].get("message", {})
    assert not message.get("tool_calls"), "unavailable video action issued a tool call"
    content = message.get("content")
    assert isinstance(content, str) and content.strip(), "missing unavailable-capability explanation"
    assert any(word in content.lower() for word in ("disabled", "unavailable", "suspended", "cannot", "can't")), "video suspension not explained"


Case = tuple[str, dict[str, Any], str, Callable[[dict[str, Any]], None]]


def cases() -> list[Case]:
    selected_b = context()
    selected_b["selected_region_id"] = "B"
    ambiguous = context()
    ambiguous["selected_region_id"] = None
    for region in ambiguous["regions"]:
        region["label"] = "Settings"
    return [
        ("sequence-hold-timing", context(),
         "At 1 second, begin moving into region A over 0.5 seconds. Hold there for 4 seconds, then take 1 second to return to full frame. Do not add a hold after the return.",
         lambda result: check_sequence(result, 1, [("A", 0.5, 4), ("full_frame", 1, 0)])),
        ("selected-scribble-reference", selected_b,
         "At 2 seconds, begin a 0.6-second move into this area, with no hold afterward.",
         lambda result: check_sequence(result, 2, [("B", 0.6, 0)])),
        ("voice-label-only", context(),
         'Label this scribble "account settings". This is just a note; do not change the video framing.', check_label),
        ("revise-selected-edit", context(),
         "Change the selected framing edit to target region B. Keep its existing time and movement duration.", check_revision),
        ("ambiguous-target", ambiguous,
         "Zoom into Settings.", check_ambiguity),
        ("honor-video-interlock", context(),
         "Export the video now.", check_unavailable),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--server-binary", default="llama-server")
    parser.add_argument("--backend", choices=("metal", "cpu"), default="metal")
    parser.add_argument("--case", choices=[case[0] for case in cases()])
    parser.add_argument("--list", action="store_true", help="Print only synthetic case names, without loading a model.")
    args = parser.parse_args()
    selected = [case for case in cases() if args.case is None or case[0] == args.case]
    if args.list:
        for name, _, _, _ in selected:
            print(name)
        return 0
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
    from local_model import LocalModelServer, default_model_path

    failed = 0
    with LocalModelServer(args.model or default_model_path(), server_binary=args.server_binary, backend=args.backend) as server:
        result_dir = server.log_dir / ("interaction-" + time.strftime("%Y%m%d-%H%M%S"))
        result_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
        for name, ctx, request, check in selected:
            messages = [{"role": "system", "content": SYSTEM},
                        {"role": "user", "content": "Editor context: " + json.dumps(ctx, separators=(",", ":")) + "\nRequest: " + request}]
            transcript: dict[str, Any] = {"prototype_only": True, "case": name, "messages": messages,
                                          "tools": copy.deepcopy(TOOLS)}
            started = time.monotonic()
            passed = False
            try:
                response = server.client.chat(messages=messages, tools=TOOLS, max_tokens=384)
                transcript["response"] = response
                check(response)
                passed = True
            except Exception as error:
                # Details may contain model output. They stay in the local file.
                transcript["failure"] = {"type": type(error).__name__, "detail": str(error)}
                failed += 1
            elapsed = time.monotonic() - started
            transcript["passed"] = passed
            transcript["elapsed_seconds"] = elapsed
            target = result_dir / (name + ".json")
            target.write_text(json.dumps(transcript, ensure_ascii=False, indent=2) + "\n")
            os.chmod(target, 0o600)
            print(f"{name}: {'PASS' if passed else 'FAIL'} ({elapsed:.2f}s)", flush=True)
    print(f"Local interaction prototype: {len(selected) - failed}/{len(selected)} checks passed. Prompts and responses remain in local files.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
