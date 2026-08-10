statusline 工作原理

核心機制

Claude Code 每次畫面更新時，會執行 settings.json 裡 statusLine.command 指定的指令，並透過 stdin 塞入一包 JSON（含 session、model、額度、context 等資訊）。腳本把 JSON 解析後，用 Write-Output 印出 1~2 行帶 ANSI 顏色的文字，Claude Code 就把它顯示在終端底部。就這樣——一個「stdin JSON 進、彩色文字出」的過濾器。

這支 statusline-command.ps1 的流程

1. 讀 stdin JSON：用 StreamReader 以 UTF-8 直讀 stdin bytes（避免中文 session_name 亂碼），ConvertFrom-Json 解析失敗會直接顯示紅字錯誤而非靜默消失。用自訂的 J 函式安全取巢狀欄位，拿到：
  - rate_limits.five_hour / seven_day 的用量 % 與重置時間
  - rate_limits.overage.used_percentage（usage credits，目前 CC 尚未吐這欄位，開放後自動顯示）
  - context_window.used_percentage（context 用量）
  - effort.level（模型 effort，跟著 session 內 /effort 切換）
  - model.display_name、workspace.current_dir、session_id
2. 額度顯示：直接用 stdin JSON 裡本帳號的 5h / 7d 用量與重置時間；有 overage 欄位時多顯示一段 credits 用量。
3. 時間進度條：Ti 比視窗長度（5h=18000 秒、7d=604800 秒），算出經過比例，畫成 8 格的 █░ 條。5h 已重置則顯示 ↻。
4. 顏色分級：用量 ≥80% 紅、≥50% 黃 。5h 用量 ≥90% 時額外顯示紅色「⚠交給Codex」警告。
5. 依終端寬度切版
  - 寬模式（≥80 欄，雙行）：第一行 = 時間、專案名、模型（含 effort，如 [Fable 5·high]）、ctx 剩餘、5h/7d 額度；第二行 = 最後訊息、Git 分支 + dirty 標記 +
  - 窄模式（<80 欄，單行）：只留時間、目錄、ctx、重置時間、額度。
6. 選用掛勾（都是「檔案存在才啟用
  - quota-handoff-guard.py：5h 用量 ≥90% 且 session 有 ID 時，把整包 JSON 寫到暫存檔，用 Start-Process 背景跑 Python 守門員，不阻塞 statusline（整個 UI）。暫存檔以 session_id 命名（同 session 覆寫同一個），並順手刪掉一小時前的殘檔。
  - codex-statusline.ps1：有的話執行並把輸出接在第二行。
  - last-session-msg-<session_id>

守門員（quota-handoff-guard.py）做的事

5h 額度撞到 90% 時寫一份交接文件到 `~\.claude\handoff\handoff-<session前8碼>-<5h重置epoch>.md`，
內容是觸發當下的額度／模型／context、git 分支與未提交變更、最近 5 筆 commit，
再從 `~\.claude\projects\*\<session_id>.jsonl` 撈最後 3 則使用者訊息與最後一則回覆。
若 `~\.claude\scripts\to-codex.mjs` 在，順手把整個 session 匯入 Codex，文件開頭放一行 `codex resume <id>`
——Codex 接的是完整對話，摘要是給人看的；匯入失敗只記 log，文件照寫。
每寫一份就在 `handoff.log` 記一行；例外也記在那裡（背景視窗是隱藏的，不記就等於沒發生）。
**同一個 5h 視窗只寫一次**：檔名即去重標記，檔案存在就直接結束；額度重置後 `resets_at` 改變，下一輪會寫新的一份。

關鍵設計點

- statusline 腳本每次刷新都會重跑吞錯、缺欄位就跳過——寧可少顯示一段，也不能整條炸掉。
- 耗時的事（Python 守門員）一律丟 n 到專案目錄再跑。
- 安裝方式見 outputs\README-Windows.md：複製到 ~\.claude\，在 settings.json 設 statusLine.command 指向它即可。