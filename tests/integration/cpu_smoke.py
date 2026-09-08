"""Opt-in POSIX test using real Whisper and generated, non-private speech."""
from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
TEXT = (
    "Welcome to the project meeting. Today we will review the schedule and discuss "
    "the next steps. Please test the software and report any problems. "
    "Thank you for your help."
)


def words(text: str) -> list[str]:
    return re.findall(r"[a-z]+", text.lower())


def word_error_rate(reference: str, actual: str) -> float:
    expected, observed = words(reference), words(actual)
    row = list(range(len(observed) + 1))
    for i, token in enumerate(expected, 1):
        new = [i]
        for j, other in enumerate(observed, 1):
            new.append(min(new[-1] + 1, row[j] + 1, row[j - 1] + (token != other)))
        row = new
    return row[-1] / max(1, len(expected))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    evidence = args.output.resolve()
    # Reusing a directory would hide whether this run produced the artifacts.
    evidence.mkdir(parents=True, exist_ok=False)
    audio = evidence / "synthetic-meeting.wav"
    report = {
        "source": "espeak-ng synthesis of the test's own fixed text; no private recordings",
        "reference": TEXT,
        "platform": platform.platform(),
        "python": sys.version,
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "model": os.environ.get("CPU_MODEL", "tiny.en"),
        "scope": "English synthetic speech; not a Mandarin, MLX, turbo or Windows benchmark",
        "runs": [],
        "passed": False,
    }
    try:
        subprocess.run(["espeak-ng", "-v", "en-us", "-s", "140", "-w", str(audio), TEXT], check=True)
        duration = float(subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(audio)], text=True,
        ).strip())
        report["audio_seconds"] = duration
        environment = os.environ.copy()
        environment.update(CPU_MODEL=report["model"], TO_TRADITIONAL="1")
        for label in ("first-run", "cached-run"):
            output = evidence / label
            command = ["bash", str(ROOT / "transcribe.sh"), str(audio), "en", "", str(output), "cpu"]
            started = time.monotonic()
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=600)
            elapsed = time.monotonic() - started
            (evidence / f"{label}.stdout.log").write_text(result.stdout, encoding="utf-8")
            (evidence / f"{label}.stderr.log").write_text(result.stderr, encoding="utf-8")
            run = {"label": label, "command": command, "exit_code": result.returncode, "wall_seconds": round(elapsed, 3)}
            report["runs"].append(run)
            if result.returncode:
                raise RuntimeError(f"{label}: CLI failed with {result.returncode}; see saved logs")
            stem = audio.stem
            files = [output / f"{stem}.{suffix}" for suffix in ("txt", "srt", "vtt", "json", "tsv")]
            if any(not path.is_file() or not path.stat().st_size for path in files):
                raise RuntimeError(f"{label}: one or more output formats are missing or empty")
            transcript = files[0].read_text(encoding="utf-8")
            data = json.loads(files[3].read_text(encoding="utf-8"))
            segments = data.get("segments", [])
            if not segments or any(s["end"] < s["start"] or s["start"] < 0 for s in segments):
                raise RuntimeError(f"{label}: missing or invalid segment timestamps")
            if segments[-1]["end"] > duration + 2:
                raise RuntimeError(f"{label}: timestamps exceed the audio duration")
            if "轉繁完成" not in result.stdout or "品質稽核 [cpu]" not in result.stdout:
                raise RuntimeError(f"{label}: conversion or QC did not complete")
            if "-->" not in files[1].read_text(encoding="utf-8") or not files[2].read_text(encoding="utf-8").startswith("WEBVTT"):
                raise RuntimeError(f"{label}: subtitle framing is missing")
            error_rate = word_error_rate(TEXT, transcript)
            run.update(transcript=transcript, word_error_rate=round(error_rate, 4), formats=[p.suffix for p in files])
            # A broad sanity check catches empty/unrelated output; this is not a quality benchmark.
            if error_rate > 0.35:
                raise RuntimeError(f"{label}: WER {error_rate:.3f} exceeds the fixed smoke threshold 0.35")
        report["passed"] = True
    finally:
        venv_python = Path(os.environ["CPU_VENV"]) / "bin/python" if "CPU_VENV" in os.environ else None
        if venv_python and venv_python.exists():
            freeze = subprocess.run([str(venv_python), "-m", "pip", "freeze"], capture_output=True, text=True)
            (evidence / "requirements-resolved.txt").write_text(freeze.stdout, encoding="utf-8")
        (evidence / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
