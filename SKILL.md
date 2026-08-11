---
name: transcribe-meeting
description: 把會議錄音/錄影（mp4/m4a/wav/mp3…）轉成逐字稿，本機 Whisper large-v3-turbo、免上傳、免 API 金鑰。雙引擎：MLX（Apple GPU，9x realtime）／CPU（fallback）／both（並排比較）。觸發詞：「轉逐字稿」「會議轉錄」「把這個錄音/影片轉文字」「transcribe」「幫我聽打會議」。
---

# 會議錄音 → 逐字稿（本機 Whisper）

把客戶會議或錄音檔轉成可供後續整理的逐字稿。全程本機執行，音檔不外傳、不需要任何雲端 API 金鑰；首次執行仍會下載套件與模型。

## 什麼時候用
使用者給一個音檔/影片檔、要求轉成文字/逐字稿/聽打會議紀錄時。

## 一次性前置（首次才需要）
- **ffmpeg**：`brew install ffmpeg`（macOS）
- **引擎不用手動裝**，`transcribe.sh` 首次執行會自動備妥（模型 ~1.5GB，首次下載需幾分鐘）
- Python 3。MLX 引擎需要 3.10–3.13 其中一版（依賴 numba，對太新的 Python 沒 wheel）；腳本會自動挑，並建在 `~/.cache/transcribe-meeting/mlx-venv`（約 1GB），**不動系統或既有的 whisper 安裝**

## 執行步驟

1. **跑轉錄腳本**（就在本 skill 資料夾內）：
   ```bash
   bash "<skill目錄>/transcribe.sh" "<輸入檔路徑>" zh "<initial_prompt>" "<輸出資料夾>" [引擎]
   ```
   - `initial_prompt` 餵**正確人名＋領域詞**能大幅降低錯字。例：`"這是一場關於 AI 報價系統的會議，參與者有 Ray 與 Ben，會談到 LINE、報價、算價、里程碑。"`
   - 輸出資料夾可省略（預設在輸入檔旁的 `transcribe_out/`）。
   - 引擎可省略（預設 `mlx`）。
   - 產出 `.txt / .srt / .vtt / .json / .tsv`。
   - 可先執行 `bash "<skill目錄>/transcribe.sh" --help` 查看完整 CLI。
   - 目標輸出資料夾已存在時，預設不覆蓋；只有確認要替換時才加 `--overwrite`，舊輸出會保留到備份資料夾。
   - 轉錄、轉繁與 QC 先在暫存 run directory 完成；成功後才發布。失敗時部分輸出會保留供診斷。

2. **選引擎**：

   | 引擎 | 說明 | 既有速度紀錄（未於本次驗證重跑）|
   |------|------|------|
   | `mlx`（預設）| Apple Silicon GPU | 參考值：2 分 48 秒（9.3x realtime） |
   | `cpu` | `openai-whisper` CPU，作為相容性 fallback | 參考值：約 35 分鐘 |
   | `both` | 兩個都跑，成功後輸出並排比較表 | MLX 時間 + CPU 時間 |

   - 非 Apple Silicon、或 MLX 準備失敗 → 明確顯示原因並退回 `cpu`；`both` 會標示比較已取消。
   - `both` 用於想親眼確認品質沒退化時。比較表會給耗時、加速倍數、段數、字數、逐字稿相似度、實質差異片段。
   - 判讀：相似度 >85% 且差異多為語助詞 → mlx 可安心用。若有整段內容只出現在一邊 → 該段人工聽一次。
   - **短檔的倍數會被稀釋**（模型載入約 13 秒固定成本）：30 秒片段只有 2–4x，5 分鐘 8.8x，25.9 分鐘 9.3x。評估效能要看長檔。

3. **判讀聲道**：腳本會先印 `mean_volume`。若數值很低（接近靜音，如 −70dB 以下）＝**混音 mono**，左右聲道相同、無法機器分軌 → 說話人要靠**內容判讀**標註（誰提問/解說＝顧問、誰講需求＝客戶）。若左右差異明顯＝真雙軌，可分軌各自標。

4. **自動轉繁**（預設開啟，不用做任何事）：Whisper 兩個引擎都會漏簡體字（實測 0.5–3%，跟段落內容有關），轉錄完會自動用 OpenCC **`s2tw`**（台灣標準字形）就地統一，五種格式都處理。腳本會印「修正 N 個簡體字」。
   - 用 `s2tw` 而非 `s2t`：實測 `s2t` 會產生「纔」「爲」「稽覈」等冷僻異體字；也不用 `s2twp`，那會連詞彙一起換（改動量 27 倍），對含專有名詞的逐字稿太激進。
   - `s2tw` 會把「台灣」正規化成「臺灣」（教育部標準用字）。不想要就設 `OPENCC_CONFIG=s2t`。
   - `both` 模式會**先轉繁再比較**，所以差異表反映的是真的內容差異，不是繁簡不一致（實測差這 5 個百分點）。
   - opencc 首次會自動裝（優先裝進 MLX venv）。裝不起來會停止發布輸出；若要明確略過轉繁，請設定 `TO_TRADITIONAL=0`；
   - 要保留原始輸出：`TO_TRADITIONAL=0`。

5. **看自動品質稽核**：轉錄完會自動印，不用再人工全篇掃：
   - `重複迴圈` — 同一句連續出現 ≥3 次 = decoder 陷入迴圈。**⚠️ 就一定要人工處理**
   - `compression_ratio>2.4` — 異常重複/亂碼的訊號
   - `幻覺樣式` — 掃「尼泊爾」「字幕by…」「請訂閱」等常見樣式
   - `覆蓋到 Xs / 音檔 Ys` — 差距太大代表尾段沒轉到
   - 稽核只抓常見樣式，**不是全面保證**；交稿前仍建議快速掃一遍。

6. **整理輸出**：依主題把破碎句子重組成可讀版本、標好說話人，存成 markdown 給使用者。

## 參數備忘
- 引擎（第 5 參數）或 `TRANSCRIBE_ENGINE` 環境變數：`mlx` / `cpu` / `both`
- `TO_TRADITIONAL=0`：關閉自動轉繁（預設 `1`）
- `OPENCC_CONFIG`：轉繁設定（預設 `s2tw`）
- 模型用環境變數覆蓋，**不用改腳本**：
  - `MLX_MODEL`（預設 `mlx-community/whisper-large-v3-turbo`）
  - `CPU_MODEL`（預設 `turbo`；機器很弱可設 `small`/`medium`）
- `zh`（第 2 參數）：中文；其他語言改對應碼（en/ja…）
- MLX 固定帶 `--condition-on-previous-text False`。**這是必要的**：預設 True 時音檔尾端的 padding 會讓 decoder 陷入重複迴圈（實測某段重複同一句 11 次、`compression_ratio` 高達 11.68 卻躲過內建閾值）。關掉後迴圈消失、速度還更快，且深處人名仍正確。

## 注意
- 音檔留在本機、不外傳——適合客戶敏感會議。
- 別預設是雙軌：會議軟體常給混音 mono，先看 `mean_volume` 再決定標註方式。
- **本 Skill 不做 speaker diarization（說話者分離）**。混音 mono 的講者歸屬只能靠內容判讀；若需要雲端分離，音檔會離開本機，必須先取得資料擁有者同意。
- 不需要 MLX 環境時 `rm -rf ~/.cache/transcribe-meeting` 即可，下次執行會自動重建。
