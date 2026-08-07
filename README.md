# transcribe-meeting — 交接安裝說明（給同事）

把「會議錄音 → 逐字稿」做成 Claude Code 技能。裝好後，只要在 Claude Code 裡說「幫我把這個錄音轉逐字稿」，Claude 就會自動處理。全程本機執行，音檔不外傳、不需 API 金鑰。

## 安裝（三步）

1. **放入技能資料夾**
   把整個 `transcribe-meeting/` 資料夾複製到：
   - 個人（所有專案都能用）：`~/.claude/skills/transcribe-meeting/`
   - 或某專案共用（隨 git repo 分享）：`<專案>/.claude/skills/transcribe-meeting/`

2. **裝 ffmpeg（一次性）**
   ```bash
   brew install ffmpeg
   ```
   轉錄引擎與 OpenCC（自動轉繁用）都不用手動裝，首次執行時腳本會自動備妥（會下載模型 ~1.5GB）。

3. **開 Claude Code 直接用**
   對 Claude 說：「幫我把 `會議.mp4` 轉成逐字稿」即可。

## 兩種引擎

| 引擎 | 條件 | 速度（25.9 分鐘會議實測）|
|------|------|------|
| `mlx`（預設）| Apple Silicon (M 系列) | **2 分 48 秒** |
| `cpu`（fallback）| 任何機器 | 約 35 分鐘 |

非 Apple Silicon 的機器會**自動退回 `cpu`**，不需要任何設定，只是慢很多。

兩種引擎都會**自動用 OpenCC `s2tw` 統一轉成繁體（台灣標準字形）**——Whisper 本身會漏簡體字，實測 0.5–3%。注意 `s2tw` 會把「台灣」正規化成「臺灣」。不想轉就設 `TO_TRADITIONAL=0`，想換設定用 `OPENCC_CONFIG`。

## 手動也能跑（不透過 Claude）
```bash
S=~/.claude/skills/transcribe-meeting/transcribe.sh

# 一般用法（預設 mlx）
bash "$S" "會議.mp4" zh "參與者有 A 與 B"

# 指定輸出資料夾
bash "$S" "會議.mp4" zh "參與者有 A 與 B" ./out

# 兩引擎並排比較（想確認品質沒退化時）
bash "$S" "會議.mp4" zh "參與者有 A 與 B" ./out both

# 強制用舊的 CPU 引擎
bash "$S" "會議.mp4" zh "參與者有 A 與 B" ./out cpu
```

## 需求
- **macOS**（Apple Silicon 可用快的 MLX 引擎；Intel Mac 或其他平台自動退回 CPU 引擎）
- **ffmpeg**
- **Python 3**。MLX 引擎需要 3.10–3.13 其中一版（依賴 numba，對太新的 Python 還沒 wheel）。腳本會自動挑，找不到就退回 CPU 引擎
- 有裝 [`uv`](https://github.com/astral-sh/uv) 會讓首次建環境快很多（沒裝也能跑，會改用 `python -m venv`）
- **硬碟約留 4GB**：MLX 模型 1.5GB + MLX 環境 1GB（`~/.cache/transcribe-meeting/`）+ CPU 版模型 1.5GB（`~/.cache/whisper/`）

## 移除
```bash
rm -rf ~/.claude/skills/transcribe-meeting   # 技能本身
rm -rf ~/.cache/transcribe-meeting           # MLX 環境（下次執行會自動重建）
rm -rf ~/.cache/whisper                      # CPU 版模型
```
