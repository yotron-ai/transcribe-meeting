# 貢獻指南

感謝你改善 `transcribe-meeting`。這個專案處理可能包含客戶機密的錄音，請優先考慮資料安全、可重現性與清楚的錯誤訊息。

## 開始前

請先閱讀：

- [README.md](README.md)：安裝、使用與限制
- [SKILL.md](SKILL.md)：Claude Code Skill 行為
- [SECURITY.md](SECURITY.md)：漏洞回報方式

## 本機驗證

以下檢查不需要 Whisper、MLX、ffmpeg、網路或大型媒體檔：

```bash
bash -n transcribe.sh
python3 -m unittest discover -s tests -v
python3 -m py_compile tests/test_transcribe.py
git diff --check HEAD
```

若修改 CLI、輸出格式、fallback、QC 或資料保護行為，請同步新增或更新離線測試。

需要驗證實際 Whisper 安裝與轉錄時，參考[真實 CPU 轉錄驗證](docs/real-cpu-test.md)。它會下載套件與模型、使用合成語音，與上面的離線測試分開執行。

## 變更原則

- 不要提交真實錄音、模型檔、逐字稿、客戶資料或憑證。
- 不要在未說明的情況下改變既有位置參數行為。
- 新增依賴時，說明用途、版本與首次下載的隱私影響。
- 失敗時優先保護既有輸出，不要刪除使用者資料。
- 使用繁體中文撰寫面向使用者的說明與錯誤訊息；保留必要的英文命令、環境變數與套件名稱。

## Pull Request

PR 內容請包含：

1. 使用者看得到的行為變更。
2. 受影響的平台與 Python 版本。
3. 實際執行的驗證命令與結果。
4. 若修改輸出格式，提供對應的 fixture 測試。

請保持每個 PR 聚焦，不要把無關的格式化或重構混進來。
