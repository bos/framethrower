"""Shared native and direct-cloud Director instructions."""
from pathlib import Path

INSTRUCTIONS = Path(__file__).with_name("instructions.txt").read_text(encoding="utf-8")
