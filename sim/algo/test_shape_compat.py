"""Compatibility gates for the three-class on-screen labels and tuner."""

from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
FONT = ROOT / "shp_font.mem"
STABLE_SHA256 = "7533d4f5207d344410b96143cac84bc70c1a0b2f0a3b76825c9e9fef876c23c7"


def check_font(words: list[str]) -> None:
    assert len(words) == 256, f"font depth changed: {len(words)}"
    assert all(word == "0000" for word in words[80:112]), "cross glyph slots 5/6 not blank"
    stable = "\n".join(words[:80] + words[112:]) + "\n"
    digest = hashlib.sha256(stable.encode("ascii")).hexdigest()
    assert digest == STABLE_SHA256, "non-cross glyph or unknown slot changed"


class ShapeCompatibilityTests(unittest.TestCase):
    def test_font_slots(self) -> None:
        check_font(FONT.read_text(encoding="ascii").splitlines())

    def test_generator_keeps_unknown_indices(self) -> None:
        out = ROOT / "outflow/diagnostics/shape_compat_generated.mem"
        out.parent.mkdir(parents=True, exist_ok=True)
        proc = subprocess.run(
            [sys.executable, str(ROOT / "tools/gen_font.py"), "--out", str(out), "--quiet"],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        check_font(out.read_text(encoding="ascii").splitlines())

    def test_tuner_preserves_legacy_protocol(self) -> None:
        spec = importlib.util.spec_from_file_location("alg_tuner", ROOT / "tools/alg_tuner.py")
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)  # imports Tk, but never opens a window or serial port
        params = {entry["cmd"]: entry for entry in module.PARAMS}
        for cmd, limits in {"S": (0, 1), "Y": (8, 255), "Z": (800, 990),
                            "W": (1, 6), "A": (5, 100)}.items():
            self.assertEqual((params[cmd]["lo"], params[cmd]["hi"]), limits)
        self.assertIn("旧版", params["Z"]["name"] + params["Z"].get("note", ""))
        self.assertNotIn("十字", (ROOT / "tools/alg_tuner.py").read_text(encoding="utf-8"))
        line = ("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 "
                "GF0400 BRG2 CAM0000=FF SHP1 SZ024 FL875 BX4 AR050\n")
        self.assertEqual(len(line.encode("ascii")), 108)
        parsed = module.TELEM_RE.fullmatch(line.rstrip("\n"))
        self.assertIsNotNone(parsed)
        self.assertEqual({k: parsed.group(k) for k in
                          ("shp_en", "shp_min", "shp_fill", "shp_nbox", "shp_area")},
                         {"shp_en": "1", "shp_min": "024", "shp_fill": "875",
                          "shp_nbox": "4", "shp_area": "050"})


if __name__ == "__main__":
    unittest.main()
