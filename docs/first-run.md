# 第一次試用與回饋

目標是先用一小段自己錄製的音訊，確認安裝、轉錄與輸出都適合你的工作流程。

## 試用前

- 依 [README](../README.md) 下載專案，備妥 Python 3.10–3.13 與 ffmpeg。
- 執行 `bash transcribe.sh --help`；這一步不會下載引擎或模型。
- 準備約 15–30 秒、包含清楚語音的自有測試音檔；避免使用客戶會議。
- 保留首次下載模型所需的網路、時間與磁碟空間。短音檔不會縮小模型下載量。

## 跑一次 CLI

在專案資料夾內執行，將檔名改為自己的檔案：

```bash
bash transcribe.sh "sample.wav" zh "專有名詞可填在這裡" ./first-run-output
```

Apple Silicon 預設嘗試 MLX；其他平台會顯示原因並改用 CPU。需要明確指定 CPU 時：

```bash
bash transcribe.sh "sample.wav" zh "" ./first-run-cpu cpu
```

每次使用新的輸出資料夾。如果已有輸出，先閱讀 README 的 `--overwrite` 備份行為再決定是否替換。

## 確認成功

1. 命令結束時顯示完成路徑，且結束碼為 0。
2. 輸出資料夾含 `.txt`、`.srt`、`.vtt`、`.json`、`.tsv`。
3. 對照自己剛錄製的內容檢查文字與字幕時間。
4. 若出現品質稽核提醒，回聽對應音訊。沒有提醒也不表示逐字稿完全正確。

「沒有音訊軌」表示 ffprobe 沒有找到可供轉錄的音軌；只有畫面的影片不能轉錄。有音軌但全程靜音則是不同情況，仍可能產生 Whisper 幻覺。

## 回報使用結果

使用 [使用回饋表單](https://github.com/yotron-ai/transcribe-meeting/issues/new?template=usage_feedback.yml)，填寫：

- 作業系統、硬體、Python 版本，以及 `git rev-parse --short HEAD` 的結果。
- 想解決的問題，例如會議逐字稿、課程字幕或訪談整理。
- 是否成功，以及最難理解或最耗時間的步驟。
- 若記錄效能，區分第一次下載與模型已有快取的執行時間，並附音檔長度及引擎。

GitHub Issue 是公開的。僅提交不敏感的摘要，先移除日誌中的姓名、私人路徑與內容；不要附錄音、逐字稿、客戶資料或金鑰。可只說明一般使用情境，不必公開公司名稱。

可重現的錯誤請用 [Bug report](https://github.com/yotron-ai/transcribe-meeting/issues/new?template=bug_report.yml)。安全漏洞請依 [安全性政策](../SECURITY.md) 回報。
