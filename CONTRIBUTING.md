# Contributing

## Before opening a pull request

Run the checks that do not require Whisper, MLX, ffmpeg, or network access:

```bash
bash -n transcribe.sh
python -m unittest discover -s tests -v
git diff --check
```

Keep changes focused. Do not add real recordings, model files, generated transcripts, or credentials to the repository.

## Pull requests

Describe the user-visible behavior, the platforms tested, and the exact verification commands and results. Changes to transcription output formats should include or update an offline fixture test.
