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

## 3. 90% 交接守門員

```powershell
Copy-Item quota-handoff-guard.py "$env:USERPROFILE\.claude\scripts\"
```

5h 額度 ≥ 90% 時，statusline 會背景叫起它（不擋 UI），它寫出一份交接文件：

```
%USERPROFILE%\.claude\handoff\handoff-<session前8碼>-<5h重置epoch>.md   交接文件
%USERPROFILE%\.claude\handoff\handoff.log                              紀錄（每寫一份一行；出錯也記這裡）
```

文件內容：觸發當下的額度／模型／context、專案的 git 分支與未提交變更、最近 5 筆 commit，
以及從 session transcript 撈出的最後 3 則使用者訊息與最後一則回覆。

若 `~/.claude/scripts/to-codex.mjs` 存在，會先把整個 session 匯入 Codex，文件開頭多一行
`codex resume <thread-id>`——Codex 拿到的是**完整對話**，上面那份摘要是給人看的。
匯入失敗只會記進 `handoff.log`，交接文件照常寫出。安裝與前提見下一節。

**同一個 5h 視窗只寫一次**——檔名就是去重標記，檔案在就直接結束。額度重置後 `resets_at` 改變，
下一個視窗再度超標時會寫新的一份。不裝這支 .py 就整段跳過，statusline 照常運作。

自我檢查：`python quota-handoff-guard.py --selftest`（寫到暫存目錄，不碰真的 handoff 資料夾）。

## 4. Codex 交接（選用）

```powershell
Copy-Item to-codex.mjs "$env:USERPROFILE\.claude\scripts\"
```

`to-codex.mjs` 把 Claude 的 session `.jsonl` 匯入成一個 Codex thread，印出 `codex resume <id>`。
守門員會在 90% 時自動呼叫它；也可以自己跑（`node to-codex.mjs [--source <claude.jsonl>]`，
不給 `--source` 就取當前專案最新的一份）。

做法是開 `codex app-server`（stdio 上的 NDJSON JSON-RPC），送一次 `externalAgentConfig/import`，
再從 `~/.codex/external_agent_session_imports.json` 讀回 thread id。**純本機轉檔**，
這步不會把對話送出去；真正送到 OpenAI 是你之後執行 `codex resume` 開始對話的時候。

沒有用 [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc) 那個官方外掛：
只需要 transfer 一項功能，裝整包會連帶吃下 `Stop` hook 的 review gate（會造成 Claude↔Codex
迴圈燒額度）與背景 job 系統；且該外掛在 Windows 下 review 類功能會靜默回空
（[issue #349](https://github.com/openai/codex-plugin-cc/issues/349)，plugin 硬寫 sandbox 並覆蓋
使用者的 `~/.codex/config.toml`）。transfer 本身不碰 sandbox，所以自己叫那支 RPC 反而乾淨。

### 前提：`codex` 要在 PATH

需要 Node，以及 `codex` 這個指令叫得到。取得方式看你原本裝了什麼：

**已裝 Codex 桌面版** — 它自帶完整 CLI（`resume` / `exec` / `app-server` 都在），
但執行檔埋在 `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`，沒有放進 PATH，
而且那層 hash 目錄每次更新都會變。放一個 shim 到 PATH 裡的個人目錄（例如 `~\.local\bin\codex.cmd`）：

```bat
@echo off
REM Shim for the Codex desktop app CLI. The bin folder is hash-named and
REM changes on every update, so resolve the newest one that has codex.exe.
setlocal
set "CODEXBIN=%LOCALAPPDATA%\OpenAI\Codex\bin"
for /f "delims=" %%d in ('dir /b /a:d /o-d "%CODEXBIN%" 2^>nul') do (
  if exist "%CODEXBIN%\%%d\codex.exe" (
    endlocal & "%LOCALAPPDATA%\OpenAI\Codex\bin\%%d\codex.exe" %*
    exit /b %errorlevel%
  )
)
echo codex.exe not found under %CODEXBIN% 1>&2
exit /b 1
```

這種情況**不要**再去 `npm i -g @openai/codex`，三個理由：

1. 兩個版本共用同一個 `~/.codex`（session store、state sqlite、auth）。桌面版通常跑在
   比 npm stable 更前面的版本，舊版讀新版寫的 state 是自找麻煩。
2. 桌面版會在 `config.toml` 寫進自己專屬的設定（`model_instructions_file`、`[windows] sandbox`、
   `notify` 與 MCP server 指向桌面版的執行檔路徑）。npm 版照樣讀這份 config，行為對不上。
3. 用 nvm for Windows 的話，global package 是綁 node 版本的——切一次版本 `codex` 就不見了。

**沒裝桌面版** — 直接 `npm i -g @openai/codex` 就好，上面那些顧慮都不存在。

## 5. 其他選用整合

- **Codex 狀態**：若存在 `<config>\scripts\codex-statusline.ps1`，其輸出會顯示在第二行（原版是 .sh，需自行改寫成 .ps1）。
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
