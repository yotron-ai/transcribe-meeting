from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "transcribe.sh"


class TranscribeCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary_directory.name)

    def tearDown(self) -> None:
        self._temporary_directory.cleanup()

    def run_script(
        self,
        *arguments: str,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        test_environment = os.environ.copy()
        test_environment.update({"LC_ALL": "C"})
        if environment is not None:
            test_environment.update(environment)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *arguments],
            capture_output=True,
            check=False,
            encoding="utf-8",
            env=test_environment,
        )

    def write_input(self, name: str) -> Path:
        input_path = self.root / name
        input_path.write_bytes(b"test media placeholder")
        return input_path

    def write_executable(self, path: Path, content: str) -> None:
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def make_fake_tools(self, *, force_mlx_platform: bool = False) -> Path:
        tools = self.root / "bin"
        tools.mkdir()
        self.write_executable(
            tools / "ffprobe",
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            "  *format=duration*) if [ \"${FAKE_FFPROBE_BAD_DURATION:-0}\" = \"1\" ]; then printf 'not-a-duration\\n'; else printf '1.0\\n'; fi ;;\n"
            "  *) printf 'audio\\n' ;;\n"
            "esac\n",
        )
        self.write_executable(
            tools / "ffmpeg",
            "#!/bin/sh\n"
            "printf 'mean_volume: -20 dB\\n' >&2\n",
        )
        self.write_executable(
            tools / "whisper",
            "#!/bin/sh\n"
            "input=\"$1\"\n"
            "shift\n"
            "output_dir=\"\"\n"
            "while [ \"$#\" -gt 0 ]; do\n"
            "  case \"$1\" in\n"
            "    --output_dir|--output-dir) output_dir=\"$2\"; shift 2 ;;\n"
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            "mkdir -p \"$output_dir\"\n"
            "base=$(basename \"$input\")\n"
            "base=${base%.*}\n"
            "printf '這是簡。\\n' > \"$output_dir/$base.txt\"\n"
            "printf '1\\n00:00:00,000 --> 00:00:01,000\\n這是簡。\\n' > \"$output_dir/$base.srt\"\n"
            "printf 'WEBVTT\\n\\n00:00.000 --> 00:01.000\\n這是簡。\\n' > \"$output_dir/$base.vtt\"\n"
            "printf '0\\t1\\t這是簡。\\n' > \"$output_dir/$base.tsv\"\n"
            "if [ \"${FAKE_WHISPER_NO_JSON:-0}\" != \"1\" ]; then\n"
            "  printf '%s\\n' '{\"segments\":[{\"start\":0,\"end\":1,\"text\":\"這是簡。\",\"compression_ratio\":1.0}]}' > \"$output_dir/$base.json\"\n"
            "fi\n",
        )
        if force_mlx_platform:
            self.write_executable(
                tools / "uname",
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  -s) printf 'Darwin\\n' ;;\n"
                "  -m) printf 'arm64\\n' ;;\n"
                "  *) /usr/bin/uname \"$@\" ;;\n"
                "esac\n",
            )
            self.write_executable(
                tools / "uv",
                "#!/bin/sh\n"
                "exit 17\n",
            )
        return tools

    def make_fake_opencc(self) -> Path:
        module_root = self.root / "fake_python"
        opencc_package = module_root / "opencc"
        opencc_package.mkdir(parents=True)
        (opencc_package / "__init__.py").write_text(
            "class OpenCC:\n"
            "    def __init__(self, config):\n"
            "        self.config = config\n"
            "\n"
            "    def convert(self, text):\n"
            "        return text.replace('簡', '繁')\n",
            encoding="utf-8",
        )
        return module_root

    def environment_for(self, tools: Path, **extra: str) -> dict[str, str]:
        path = f"{tools}:{os.environ.get('PATH', '')}"
        environment = {"PATH": path, "XDG_CACHE_HOME": str(self.root / "cache")}
        environment.update(extra)
        return environment

    def test_help_is_available_without_runtime_dependencies(self) -> None:
        result = self.run_script("--help", environment={"PATH": "/nonexistent"})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--help", result.stdout)
        self.assertIn("--overwrite", result.stdout)
        self.assertIn("both", result.stdout)

    def test_missing_input_is_a_clear_cli_error(self) -> None:
        result = self.run_script()

        self.assertEqual(result.returncode, 2)
        self.assertIn("缺少輸入檔", result.stderr)

    def test_invalid_engine_is_rejected_before_runtime_setup(self) -> None:
        result = self.run_script(str(self.root / "recording.mp3"), "zh", "", "out", "gpu")

        self.assertEqual(result.returncode, 2)
        self.assertIn("引擎只能是 mlx / cpu / both", result.stderr)

    def test_non_media_extension_is_rejected_when_ffprobe_cannot_help(self) -> None:
        tools = self.make_fake_tools()
        self.write_executable(tools / "ffprobe", "#!/bin/sh\nexit 1\n")
        input_path = self.write_input("notes.txt")
        result = self.run_script(
            str(input_path),
            environment=self.environment_for(tools),
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("ffprobe 無法讀取輸入檔", result.stderr)

    def test_output_conversion_and_qc_publish_only_after_success(self) -> None:
        tools = self.make_fake_tools()
        opencc = self.make_fake_opencc()
        input_path = self.write_input("recording.wav")
        output_path = self.root / "out"
        result = self.run_script(
            str(input_path),
            "zh",
            "",
            str(output_path),
            "cpu",
            environment=self.environment_for(
                tools,
                PYTHONPATH=str(opencc),
                TO_TRADITIONAL="1",
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("轉繁完成", result.stdout)
        self.assertIn("品質稽核 [cpu]", result.stdout)
        self.assertEqual((output_path / "recording.txt").read_text(encoding="utf-8"), "這是繁。\n")
        transcription = json.loads((output_path / "recording.json").read_text(encoding="utf-8"))
        self.assertEqual(transcription["segments"][0]["text"], "這是繁。")

    def test_existing_output_is_preserved_without_overwrite(self) -> None:
        tools = self.make_fake_tools()
        input_path = self.write_input("recording.wav")
        output_path = self.root / "out"
        output_path.mkdir()
        marker = output_path / "keep.txt"
        marker.write_text("keep", encoding="utf-8")
        result = self.run_script(
            str(input_path),
            "zh",
            "",
            str(output_path),
            "cpu",
            environment=self.environment_for(tools, TO_TRADITIONAL="0"),
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("既有內容未變更", result.stderr)
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

    def test_overwrite_publishes_new_output_and_keeps_backup(self) -> None:
        tools = self.make_fake_tools()
        input_path = self.write_input("recording.wav")
        output_path = self.root / "out"
        output_path.mkdir()
        (output_path / "keep.txt").write_text("old", encoding="utf-8")
        result = self.run_script(
            "--overwrite",
            str(input_path),
            "zh",
            "",
            str(output_path),
            "cpu",
            environment=self.environment_for(tools, TO_TRADITIONAL="0"),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((output_path / "recording.txt").is_file())
        backups = list(self.root.glob(".transcribe-meeting-backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "previous" / "keep.txt").read_text(encoding="utf-8"), "old")

    def test_failed_qc_keeps_partial_run_outside_publish_target(self) -> None:
        tools = self.make_fake_tools()
        input_path = self.write_input("recording.wav")
        output_path = self.root / "out"
        result = self.run_script(
            str(input_path),
            "zh",
            "",
            str(output_path),
            "cpu",
            environment=self.environment_for(
                tools,
                TO_TRADITIONAL="0",
                FAKE_WHISPER_NO_JSON="1",
            ),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output_path.exists())
        self.assertIn("輸出不完整", result.stderr)
        partial_path = result.stderr.split("部分輸出保留於: ", 1)[1].splitlines()[0]
        self.assertTrue(Path(partial_path).is_dir())
        self.assertTrue(any(Path(partial_path).rglob("*.txt")))

    def test_both_mlxfailure_is_reported_and_runs_cpu_only(self) -> None:
        tools = self.make_fake_tools(force_mlx_platform=True)
        input_path = self.write_input("recording.wav")
        output_path = self.root / "out"
        result = self.run_script(
            str(input_path),
            "zh",
            "",
            str(output_path),
            "both",
            environment=self.environment_for(tools, TO_TRADITIONAL="0"),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("比較已取消，僅執行 CPU", result.stdout)
        self.assertIn("模式: cpu", result.stdout)
        self.assertNotIn("引擎並排比較", result.stdout)
        self.assertTrue((output_path / "recording.txt").is_file())
        self.assertFalse((output_path / "mlx").exists())
        self.assertFalse((output_path / "cpu").exists())
    def test_both_invalid_duration_still_runs_cpu_fallback(self) -> None:
        tools = self.make_fake_tools(force_mlx_platform=True)
        input_path = self.write_input("recording.wav")
        output_path = self.root / "out"
        result = self.run_script(
            str(input_path),
            "zh",
            "",
            str(output_path),
            "both",
            environment=self.environment_for(
                tools,
                TO_TRADITIONAL="0",
                FAKE_FFPROBE_BAD_DURATION="1",
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("比較已取消，僅執行 CPU", result.stdout)
        self.assertTrue((output_path / "recording.txt").is_file())

    def test_output_symlink_is_rejected_without_touching_target(self) -> None:
        tools = self.make_fake_tools()
        input_path = self.write_input("recording.wav")
        real_output = self.root / "real-out"
        real_output.mkdir()
        marker = real_output / "keep.txt"
        marker.write_text("keep", encoding="utf-8")
        output_link = self.root / "out"
        output_link.symlink_to(real_output, target_is_directory=True)
        result = self.run_script(
            str(input_path),
            "zh",
            "",
            str(output_link),
            "cpu",
            environment=self.environment_for(tools, TO_TRADITIONAL="0"),
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("symbolic link", result.stderr)
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

    def test_output_containing_input_is_rejected(self) -> None:
        tools = self.make_fake_tools()
        input_path = self.write_input("recording.wav")
        result = self.run_script(
            "--overwrite",
            str(input_path),
            "zh",
            "",
            str(self.root),
            "cpu",
            environment=self.environment_for(tools, TO_TRADITIONAL="0"),
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("包含輸入檔", result.stderr)


if __name__ == "__main__":
    unittest.main()
