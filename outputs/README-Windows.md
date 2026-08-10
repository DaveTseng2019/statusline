# Status Line — Windows PowerShell 版安裝說明

`statusline-command.ps1` 是原 bash 腳本的完整移植，功能全部保留：
5h/7d 額度與時間進度條、ctx 剩餘、Git 分支與增刪、Codex 整合、90% 交接警告、寬/窄雙模式。

不需要 jq、不需要 Git Bash，Windows 內建的 PowerShell 5.1 即可（PowerShell 7 也相容）。

## 1. 複製腳本

```powershell
Copy-Item statusline-command.ps1 "$env:USERPROFILE\.claude\"
```

## 2. 設定 Claude Code

編輯 `%USERPROFILE%\.claude\settings.json`：

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\dave\\.claude\\statusline-command.ps1"
  }
}
```

若已安裝 PowerShell 7，把 `powershell.exe` 換成 `pwsh.exe` 啟動更快。

## 3. 選用整合

- **Codex 狀態**：若存在 `<config>\scripts\codex-statusline.ps1`，其輸出會顯示在第二行（原版是 .sh，需自行改寫成 .ps1）。
- **90% 交接守門員**：若存在 `%USERPROFILE%\.claude\scripts\quota-handoff-guard.py` 且系統有 `python`，會在背景執行（不擋 status line）。
- **最後訊息**：讀取 `%USERPROFILE%\.claude\last-session-msg-<session_id>`（若有）。

## 需求

- Windows PowerShell 5.1（Windows 10/11 內建）或 PowerShell 7+
- Git 資訊需要 `git` 在 PATH
- 建議使用 Windows Terminal（ANSI truecolor 支援）；腳本檔案已含 UTF-8 BOM，請勿以非 UTF-8 編碼另存

## 與 bash 版的差異

- jq → 內建 `ConvertFrom-Json`
- `~/.claude` → `%USERPROFILE%\.claude`
- codex 整合腳本副檔名改為 `.ps1`
- 其餘顯示格式、顏色、邏輯一致
