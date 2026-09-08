# 真實 CPU 轉錄驗證

離線測試用假的 Whisper 驗證控制流程；這份整合測試則實際下載並執行 Whisper，以確認引擎、轉繁、品質稽核與五種輸出能一起工作。

## 測試範圍

- Ubuntu 24.04、Python 3.12、CPU 版 PyTorch 2.5.1。
- 使用專案預設固定版本的 `openai-whisper` 與 OpenCC。
- 以 espeak-ng 從測試內自寫的英文文字合成語音，不使用私人錄音。
- 使用 `tiny.en`，不等同預設 `turbo`、中文會議、MLX 或 Windows 的驗證。
- 依序執行首次與已有快取兩次轉錄；記錄整個 CLI 耗時。首次包含引擎套件安裝、模型與 OpenCC 準備，CI 的作業系統工具及 PyTorch 安裝時間另計。

不宣稱此固定合成語音能代表一般會議準確率；它只用來攔下整合流程故障。

## 如何執行

GitHub Actions 的 **Real CPU transcription** 工作流程會在腳本或整合測試變更的 push 時執行，也可從 Actions 頁使用 **Run workflow** 手動觸發。每個 job 最多 15 分鐘。

本機限已有 Bash、Python 3.10–3.13、ffmpeg、espeak-ng 的 POSIX 環境：

```bash
CPU_MODEL=tiny.en python3 tests/integration/cpu_smoke.py --output ./smoke-evidence
```

輸出資料夾必須不存在；若要重跑請換新路徑。第一次會下載引擎與模型，測試不是完全離線。CI 會先準備 CPU 專用 PyTorch，再交給專案腳本安裝其餘引擎套件；本機依既有引擎與硬體而定。

## 檢查與證據

測試要求兩次 CLI 都成功、五種格式非空、JSON 段落時間合理、字幕包含基本格式，且 OpenCC 與品質稽核實際完成。

另外計算固定英文樣本的詞錯誤率（WER）：轉成小寫、取英文字詞後計算插入、刪除、替換距離，除以參考字數。大於 0.35 會失敗，這是流程煙霧測試的固定容忍值，不是產品品質標準。

GitHub run artifact 會保留 14 天，包含：

- `report.json`：commit、平台、模型、逐次結果、耗時與詞錯誤率。
- `requirements-resolved.txt`：CI CPU 環境實際安裝的套件版本。
- 合成音訊、五種轉錄輸出與 stdout/stderr 日誌。

這些都是合成測試資料。一般使用者回報問題時仍不應上傳私人會議內容。測試失敗請查看 run artifact；不要調低標準或改寫結果來製造通過。
