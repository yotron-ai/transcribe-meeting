# transcribe-meeting — 本機會議逐字稿

把會議錄音或影片轉成 `.txt / .srt / .vtt / .json / .tsv`，可作為 Claude Code skill 使用。音檔與逐字稿都在本機處理，不需要 API 金鑰；但首次使用會下載 Python 套件與模型，這是本機隱私邊界的一部分。

## 安裝

把整個 `transcribe-meeting/` 資料夾複製到：

- 個人技能：`~/.claude/skills/transcribe-meeting/`
- 專案共用：`<專案>/.claude/skills/transcribe-meeting/`

安裝 `ffmpeg`（同時提供 `ffprobe`）：

```bash
brew install ffmpeg
```

Python 3.10–3.13 至少需要其中一版。`uv` 是可選的；有它會加快建立 venv，沒有也會使用 `python -m venv` 與該環境自己的 pip。

## 手動使用

先看完整說明，這條路徑不會初始化任何轉錄引擎：

```bash
bash transcribe.sh --help
```

既有 positional 參數順序保持不變：

```bash
S=~/.claude/skills/transcribe-meeting/transcribe.sh

# 預設 mlx；輸出預設為輸入檔旁的 transcribe_out/
bash "$S" "會議.mp4" zh "參與者有 A 與 B"

# 指定輸出與 CPU 引擎
bash "$S" "會議.mp4" zh "參與者有 A 與 B" ./out cpu

# 兩引擎比較
bash "$S" "會議.mp4" zh "參與者有 A 與 B" ./out both

# 只有在確認要替換既有輸出時使用；舊資料會保留到備份資料夾
bash "$S" --overwrite "會議.mp4" zh "" ./out cpu
```

輸入會先確認檔案存在且可讀。副檔名不在支援清單時會拒絕；有 `ffprobe` 時則會再確認檔案含 `audio` 或 `video` stream。沒有 `ffprobe` 時，支援的副檔名只能提供基本檢查，實際解碼仍由 `ffmpeg` 負責。

## 引擎與 `both` 語義

| 引擎 | 條件 | 結果 |
|------|------|------|
| `mlx`（預設） | Apple Silicon | MLX GPU；非 Apple Silicon 或 MLX 準備失敗會明確改跑 CPU |
| `cpu` | 可用的 Python 環境 | `openai-whisper` CPU |
| `both` | MLX 與 CPU 都可用 | 兩邊都完成 QC 後才產生比較 |

`both` 如果平台不是 Apple Silicon，或 MLX venv／套件準備失敗，會印出 `comparison cancelled`，只執行 CPU，不會產生假比較表。CPU 成功時退出碼為 `0`；CPU 失敗時為非零，並保留暫存 run directory 的部分輸出供診斷。

## 輸出安全

- 轉錄先寫入輸出父資料夾下的 `.transcribe-meeting-run.*` 暫存目錄。
- 只有輸出格式完整、OpenCC 轉繁成功（預設開啟）與 QC 成功後，才會發布到目標資料夾。
- 目標資料夾已存在時，預設停止且不修改既有內容。
- `--overwrite` 會先把整個既有輸出資料夾移到 `.transcribe-meeting-backup.* / previous`，成功後才發布新輸出；不刪除舊資料。
- 失敗時不清理暫存 run directory，錯誤訊息會給出路徑。
- 若不想使用 OpenCC，請明確設定 `TO_TRADITIONAL=0`；未明確略過時，OpenCC 無法使用會使本次不發布。

## 依賴隔離與版本

腳本不再在找不到 CPU 引擎時直接 `pip install --user`。它會先重用現有的 `whisper` 指令，否則在快取下建立專用 CPU venv：

`$XDG_CACHE_HOME/transcribe-meeting/`（未設定時通常是 `~/.cache/transcribe-meeting/`）

| 用途 | 預設套件版本 | 預設模型／設定 |
|------|--------------|----------------|
| MLX | `mlx-whisper==0.4.2` | `mlx-community/whisper-large-v3-turbo` |
| CPU | `openai-whisper==20240930` | `turbo` |
| 轉繁 | `opencc-python-reimplemented==0.1.7` | `s2tw` |

套件版本與模型可用環境變數覆蓋：`MLX_PACKAGE`、`CPU_PACKAGE`、`OPENCC_PACKAGE`、`MLX_MODEL`、`CPU_MODEL`。固定預設版本是可重現性基準；不同 Python／平台 wheel 不相容時再用環境變數明確調整。

套件與模型會在首次需要時下載，可能需要數 GB 磁碟與網路。腳本本身不把音檔上傳到雲端，也不會呼叫雲端轉錄 API；套件索引與模型主機的網路連線不等於音檔外傳。

## 限制

- 需要 `ffmpeg`；MLX 只適用 Apple Silicon。
- `s2tw` 會將「台灣」正規化為「臺灣」；可用 `OPENCC_CONFIG=s2t` 或 `TO_TRADITIONAL=0` 調整。
- 聲道檢查只協助判斷是否可能是混音 mono，不做 speaker diarization。混音 mono 的講者歸屬仍需人工依內容判讀。
- QC 只抓重複迴圈、compression ratio 與少數常見幻覺樣式，不是逐字稿正確性的保證。
- 速度表現受硬體、模型快取與音檔長度影響。README 早期的實測數字是既有紀錄，本次沒有重跑，不作為新的 benchmark。

## 測試與 CI

測試只使用 Python 標準庫與假的 `ffmpeg`／`ffprobe`／`whisper`，不需要 Whisper、MLX、ffmpeg、網路或大型媒體：

```bash
bash -n transcribe.sh
python3 -m unittest discover -s tests -v
python3 -m py_compile tests/test_transcribe.py
git diff --check
```

GitHub Actions 會在 push／pull request 執行相同的語法、測試與基本靜態檢查。

## 移除快取

確認路徑後再逐一移除；這些命令不會碰輸入檔或已發布輸出：

```bash
rm -ri ~/.claude/skills/transcribe-meeting
rm -ri ~/.cache/transcribe-meeting
rm -ri ~/.cache/whisper
```
