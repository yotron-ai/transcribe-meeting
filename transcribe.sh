#!/usr/bin/env bash
# 會議錄音/影片 → 逐字稿（本機 Whisper turbo）
# 可攜版：自動偵測/安裝 whisper，不寫死任何個人路徑。
#
# 用法:
#   transcribe.sh <輸入檔> [語言=zh] [initial_prompt] [輸出資料夾]
# 範例:
#   transcribe.sh "會議.mp4" zh "這是一場關於報價系統的會議，參與者有 Ray 與 Ben。" ./out
set -euo pipefail

INPUT="${1:?請提供音檔/影片路徑（.mp4/.m4a/.wav/.mp3…）}"
# 注意：變數名不可用 LANG（那是系統 locale 環境變數，覆蓋會破壞 UTF-8 處理）
WHISPER_LANG="${2:-zh}"
PROMPT="${3:-}"
OUTDIR="${4:-$(dirname "$INPUT")/transcribe_out}"

# --- 找 whisper（不寫死路徑，跨機器） ---
find_whisper() {
  command -v whisper 2>/dev/null && return 0
  local ub; ub="$(python3 -m site --user-base 2>/dev/null || true)"
  [ -n "$ub" ] && [ -x "$ub/bin/whisper" ] && { echo "$ub/bin/whisper"; return 0; }
  for p in "$HOME/Library/Python/"*/bin/whisper "$HOME/.local/bin/whisper"; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# --- 前置檢查 ---
command -v python3 >/dev/null 2>&1 || { echo "❌ 找不到 python3，請先安裝 Python 3"; exit 1; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "❌ 找不到 ffmpeg。macOS 請執行：brew install ffmpeg"; exit 1; }

WHISPER="$(find_whisper)" || {
  echo "⚠️  未偵測到 openai-whisper，正在安裝（首次約需幾分鐘）..."
  python3 -m pip install --user -U openai-whisper >/dev/null
  WHISPER="$(find_whisper)" || { echo "❌ 安裝後仍找不到 whisper，請手動確認 pip 安裝路徑是否在 PATH"; exit 1; }
}
echo "✔ 使用 whisper: $WHISPER"

mkdir -p "$OUTDIR"

# --- (1) 測是不是混音 mono（決定能否分軌） ---
echo "▶ 檢查聲道（混音 mono 判斷）..."
MEAN="$(ffmpeg -i "$INPUT" -af "pan=mono|c0=c0-c1,volumedetect" -f null - 2>&1 | grep mean_volume || true)"
echo "   $MEAN"
echo "   （mean_volume 很低≈靜音 → 左右聲道幾乎相同＝混音 mono，無法機器分軌，說話人需靠內容判讀）"

# --- (2) 轉錄 ---
echo "▶ 開始轉錄（model=turbo, lang=$WHISPER_LANG）首次會下載模型(~1.5GB)..."
if [ -n "$PROMPT" ]; then
  "$WHISPER" "$INPUT" --language "$WHISPER_LANG" --model turbo --output_format all \
    --initial_prompt "$PROMPT" --output_dir "$OUTDIR" --verbose False
else
  "$WHISPER" "$INPUT" --language "$WHISPER_LANG" --model turbo --output_format all \
    --output_dir "$OUTDIR" --verbose False
fi

echo "✅ 完成 → $OUTDIR （產出 .txt/.srt/.vtt/.json/.tsv）"
echo "⚠️  近靜音段 Whisper 可能生幻覺（如「尼泊爾」「字幕by…」），標註前人工掃一遍刪掉。"
