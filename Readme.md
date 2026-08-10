statusline 工作原理

核心機制

Claude Code 每次畫面更新時，會執行 settings.json 裡 statusLine.command 指定的指令，並透過 stdin 塞入一包 JSON（含 session、model、額度、context 等資訊）。腳本把 JSON 解析後，用 Write-Output 印出 1~2 行帶 ANSI 顏色的文字，Claude Code 就把它顯示在終端底部。就這樣——一個「stdin JSON 進、彩色文字出」的過濾器。

這支 statusline-command.ps1 的流程

1. 讀 stdin JSON（第 9-11 行）：[Console]::In.ReadToEnd() + ConvertFrom-Json，用自訂的 J 函式安全取巢狀欄位，拿到：
  - rate_limits.five_hour / seven_day 的用量 % 與重置時間
  - context_window.used_percentage（context 用量）
  - model.display_name、workspace.current_dir、session_id
2. 額度顯示：直接用 stdin JSON 裡本帳號的 5h / 7d 用量與重置時間。
3. 時間進度條（第 115-123 行）：Ti 比視窗長度（5h=18000 秒、7d=604800 秒），算出經過比例，畫成 8 格的 █░ 條。5h 已重置則顯示 ↻。
4. 顏色分級：用量 ≥80% 紅、≥50% 黃 。5h 用量 ≥90% 時額外顯示紅色「⚠交給Codex」警告。
5. 依終端寬度切版
  - 寬模式（≥80 欄，雙行）：第一行 = 時間、專案名、模型、ctx 剩餘、5h/7d 額度；第二行 = 最後訊息、Git 分支 + dirty 標記 +
  - 窄模式（<80 欄，單行）：只留時間、目錄、ctx、重置時間、額度。
6. 選用掛勾（都是「檔案存在才啟用
  - quota-handoff-guard.py：session 有 ID 時，把整包 JSON 存到暫存檔，用 Start-Process 背景跑
Python 守門員，不阻塞 statusline（整個 UI）。
  - codex-statusline.ps1：有的話執行並把輸出接在第二行。
  - last-session-msg-<session_id>

關鍵設計點

- statusline 腳本每次刷新都會重跑吞錯、缺欄位就跳過——寧可少顯示一段，也不能整條炸掉。
- 耗時的事（Python 守門員）一律丟 n 到專案目錄再跑。
- 安裝方式見 outputs\README-Windows.md：複製到 ~\.claude\，在 settings.json 設 statusLine.command 指向它即可。