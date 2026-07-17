# transcribe-meeting

A **Claude Code skill** that turns meeting recordings/videos into transcripts using **local Whisper** — no upload, no API key, audio never leaves your machine.

會議錄音/錄影 → 逐字稿的 Claude Code 技能。本機 Whisper turbo，音檔不外傳、免 API 金鑰。裝好後在 Claude Code 說「幫我把這個錄音轉逐字稿」即可。

---

## 安裝 Install

直接 clone 進 Claude Code 的技能資料夾：

```bash
# 個人（所有專案可用）
git clone https://github.com/roy6732856/transcribe-meeting ~/.claude/skills/transcribe-meeting

# 一次性依賴（macOS）
brew install ffmpeg
```

`openai-whisper` 不用手動裝——首次轉錄時腳本會自動 `pip install --user`（會下載模型 ~1.5GB）。

## 使用 Usage

**在 Claude Code 裡**（推薦）：
> 幫我把 `會議.mp4` 轉成逐字稿

Claude 會自動偵測到本技能並執行。

**手動 CLI**：
```bash
bash ~/.claude/skills/transcribe-meeting/transcribe.sh "會議.mp4" zh "參與者有 A 與 B，會談到報價、里程碑"
# 參數：<輸入檔> [語言=zh] [initial_prompt] [輸出資料夾]
```
產出 `.txt / .srt / .vtt / .json / .tsv`。

## 特色 Features

- **全本機**：適合客戶敏感會議，音檔不外傳、不需雲端 API。
- **可攜**：自動偵測/安裝 whisper，不寫死任何個人路徑。
- **混音 mono 判斷**：先測左右聲道差（`mean_volume`）。接近靜音＝混音 mono、無法機器分軌 → 說話人靠內容判讀。
- **幻覺提醒**：近靜音段 Whisper 常生幻覺（「尼泊爾」「字幕by…」），交稿前人工掃一遍刪掉。

## 需求 Requirements

- macOS + Python 3（系統內建即可）+ ffmpeg
- 硬碟約 2GB（Whisper turbo 模型）

## License

MIT
