# transcribe-meeting

> 在本機把會議錄音或影片轉成逐字稿；音檔不上傳、不需要雲端 API 金鑰。

這是一個可安裝為 Claude Code Skill 的本機轉錄工具，支援 Whisper 的 MLX 與 CPU 引擎，並輸出 `.txt`、`.srt`、`.vtt`、`.json`、`.tsv` 五種格式。

首次使用仍需要網路下載 Python 套件與 Whisper 模型；「不上傳音檔」不代表完全離線。

## 功能摘要

- Apple Silicon 優先使用 MLX GPU；不支援或準備失敗時明確退回 CPU。
- `both` 模式可比較 MLX 與 CPU 結果；若 MLX 失敗，不會產生假比較表。
- 預設使用 OpenCC `s2tw` 將輸出轉為臺灣繁體字形。
- 轉錄、轉繁與品質稽核完成後才發布正式輸出，避免半成品覆蓋資料。
- 既有輸出預設不覆蓋；`--overwrite` 會先保留完整備份。
- 所有測試不需要下載 Whisper、MLX、ffmpeg、網路或大型媒體檔。

## 快速開始

### 1. 安裝前置工具

macOS：

```bash
brew install ffmpeg
```

需要 Python 3.10–3.13；安裝 `uv` 可加快建立虛擬環境，但不是必要條件。

### 2. 下載與驗證安裝

可以直接用 CLI，不需要先安裝 Claude Code：

```bash
git clone https://github.com/yotron-ai/transcribe-meeting.git
cd transcribe-meeting
bash transcribe.sh --help
```

`--help` 不會下載模型，也不會開始轉錄。第一次實際試用建議使用自己錄製的短音檔；先確認輸出符合需求，再處理長會議。

目前安裝流程以 macOS 與具備 Bash、Python 3.10–3.13、ffmpeg 的 Linux 環境為主。Windows 原生 PowerShell 與 Git Bash 尚未完成完整轉錄驗證；不要把安裝成功或 `--help` 通過當成引擎相容性保證。

### 3. 安裝 Claude Code Skill（選用）

將整個 repo 複製到以下其中一個位置：

```text
個人使用：~/.claude/skills/transcribe-meeting/
專案共用：<專案>/.claude/skills/transcribe-meeting/
```

### 4. 先查看 CLI 說明

```bash
bash transcribe.sh --help
```

### 5. 執行轉錄

```bash
S=~/.claude/skills/transcribe-meeting/transcribe.sh

# 使用預設 MLX；輸出到輸入檔旁的 transcribe_out/
bash "$S" "會議.mp4" zh "參與者有 A 與 B"

# 指定輸出資料夾與 CPU 引擎
bash "$S" "會議.mp4" zh "參與者有 A 與 B" ./out cpu

# 執行 MLX 與 CPU 比較
bash "$S" "會議.mp4" zh "參與者有 A 與 B" ./out both

# 確認要替換既有輸出時使用；舊資料會保留在備份資料夾
bash "$S" --overwrite "會議.mp4" zh "" ./out cpu
```

也可以直接在 Claude Code 說：「幫我把這個錄音轉成逐字稿」。

## 指令參數

既有位置參數順序保持相容：

```text
transcribe.sh [選項] <輸入檔> [語言=zh] [initial_prompt] [輸出資料夾] [引擎=mlx|cpu|both]
```

| 參數 | 說明 |
|---|---|
| `-h`, `--help` | 顯示說明，不初始化任何引擎 |
| `--overwrite` | 成功後替換既有輸出，舊資料先移至備份資料夾 |
| `--` | 結束選項解析，允許輸入路徑或 prompt 以 `-` 開頭 |
| `語言` | Whisper 語言代碼，例如 `zh`、`en`、`ja` |
| `initial_prompt` | 人名、產品名與領域詞，可降低專有名詞錯字 |
| `輸出資料夾` | 預設為輸入檔旁的 `transcribe_out/` |
| `引擎` | `mlx`、`cpu` 或 `both` |

## 引擎行為

| 引擎 | 適用情境 | 行為 |
|---|---|---|
| `mlx` | Apple Silicon | 使用 MLX GPU；不支援或準備失敗時明確改跑 CPU |
| `cpu` | 需要相容性或 fallback | 使用 `openai-whisper` CPU |
| `both` | 驗證 MLX 品質 | 兩邊都完成後才產生比較；MLX 失敗時只跑 CPU 並標示 `comparison cancelled` |

`both` 模式的比較會列出耗時、加速倍數、段數、字數、相似度與實質差異片段。相似度不是正確率保證；出現整段內容差異時，仍要人工聽取原音檔。

## 輸出安全與失敗處理

1. 先檢查檔案存在、可讀，並在 `ffprobe` 可用時確認至少有一條音訊軌。只有畫面或字幕的影片會在準備引擎前停止；這項檢查不判定音軌是否靜音。
2. 轉錄結果先寫入 `.transcribe-meeting-run.*` 暫存資料夾。
3. 五種輸出格式、OpenCC 轉繁與品質稽核都通過後，才移至正式輸出資料夾。
4. 目標資料夾已存在時，預設停止且不修改既有內容。
5. 使用 `--overwrite` 時，舊輸出會移到 `.transcribe-meeting-backup.*/previous`，不會刪除。
6. 失敗時會保留暫存資料夾，錯誤訊息會提供診斷路徑。

預設 OpenCC 無法使用時不發布輸出；若確定要保留原始繁簡混合結果，請明確設定：

```bash
TO_TRADITIONAL=0 bash "$S" "會議.mp4" zh "" ./out cpu
```

## 依賴與快取

腳本不會把 CPU 依賴直接安裝到 user site。缺少引擎時，會在以下位置建立專用快取環境：

```text
${XDG_CACHE_HOME:-~/.cache}/transcribe-meeting/
```

| 用途 | 預設套件版本 | 預設模型或設定 |
|---|---|---|
| MLX | `mlx-whisper==0.4.2` | `mlx-community/whisper-large-v3-turbo` |
| CPU | `openai-whisper==20240930` | `turbo` |
| 轉繁 | `opencc-python-reimplemented==0.1.7` | `s2tw` |

可用環境變數覆蓋：

```text
MLX_PACKAGE / CPU_PACKAGE / OPENCC_PACKAGE
MLX_MODEL / CPU_MODEL
TO_TRADITIONAL / OPENCC_CONFIG
TRANSCRIBE_ENGINE
```

模型與套件可能需要數 GB 磁碟空間。模型下載主機與套件索引會被連線，但腳本不會把音檔送往雲端轉錄服務。

## 品質稽核與限制

腳本會檢查：

- 連續重複句子
- `compression_ratio > 2.4`
- 少數常見幻覺文字
- 逐字稿覆蓋時間與音檔長度差異

這些只是提醒，不是逐字稿正確性的保證。另請注意：

- 不提供 speaker diarization；混音 mono 的講者需要人工依內容判讀。
- `s2tw` 會把「台灣」正規化為「臺灣」；可改用 `OPENCC_CONFIG=s2t` 或關閉轉繁。
- 實際速度取決於硬體、模型快取、語言與音檔長度；README 不宣稱未重新驗證的 benchmark。

## 開發與測試

```bash
bash -n transcribe.sh
python3 -m unittest discover -s tests -v
python3 -m py_compile tests/test_transcribe.py
git diff --check
```

測試使用假的 `ffmpeg`、`ffprobe`、`whisper` 與 OpenCC 模組，不會下載模型或處理真實錄音。

GitHub Actions 會在 push 與 pull request 執行語法檢查、離線測試與差異檢查。

## 清理

確認路徑後再執行；以下命令不會碰已發布輸出：

```bash
rm -ri ~/.claude/skills/transcribe-meeting
rm -ri ~/.cache/transcribe-meeting
rm -ri ~/.cache/whisper
```

## 參與貢獻

第一次使用可參考[試用與回饋指南](docs/first-run.md)。如果已成功使用，也歡迎透過 [使用回饋](https://github.com/yotron-ai/transcribe-meeting/issues/new?template=usage_feedback.yml) 告訴我們使用平台、用途與卡住的步驟；不需要提供錄音或逐字稿。

- [貢獻指南](CONTRIBUTING.md)
- [安全性政策](SECURITY.md)
- [變更記錄](CHANGELOG.md)
- [MIT License](LICENSE)
