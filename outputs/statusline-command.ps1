# ~\.claude\statusline-command.ps1
# Claude Code status line (Windows PowerShell 版) — quota + context bar + git 資訊
# 相容 Windows PowerShell 5.1 與 PowerShell 7+

$OutputEncoding = [Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}

# notes: 繼承到 NO_COLOR（或 TERM=dumb）時 PS 7.2+ 會把 OutputRendering 設成 PlainText，
#        連字串裡自己寫的 ANSI 都會被剝掉，整條 statusline 變單色。這裡的顏色是給 CC 渲染用的，強制開。
if ($PSStyle) { $PSStyle.OutputRendering = 'Ansi' }

# --- 讀取 stdin JSON ---
# notes: 直接以 UTF-8 讀 stdin bytes。用 [Console]::InputEncoding 在 stdin 被重導向時可能設定失敗，
# 中文 session_name 會變亂碼、吃掉引號使 JSON 非法，下面的 catch 靜默吞掉後整條 statusline 只剩時間。
$raw = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false))).ReadToEnd()
$data = $null
# notes: 不要吞掉解析錯誤。靜默失敗時所有欄位變 null，statusline 只剩時間，看起來像「消失」但沒有任何線索。
try { $data = $raw | ConvertFrom-Json } catch {
  Write-Output "$([char]27)[0;31m[statusline] JSON 解析失敗: $($_.Exception.Message)$([char]27)[0m"
}

# 安全取巢狀屬性
function J($o, [string[]]$path) {
  foreach ($p in $path) {
    if ($null -eq $o) { return $null }
    $prop = $o.PSObject.Properties[$p]
    if ($null -eq $prop) { return $null }
    $o = $prop.Value
  }
  return $o
}

# --- 解析欄位 ---
$five_pct   = J $data @('rate_limits','five_hour','used_percentage')
$five_reset = J $data @('rate_limits','five_hour','resets_at')
$week_pct   = J $data @('rate_limits','seven_day','used_percentage')
$week_reset = J $data @('rate_limits','seven_day','resets_at')
$ctx_used   = J $data @('context_window','used_percentage')
$effort     = J $data @('effort','level')
$ovr_pct    = J $data @('rate_limits','overage','used_percentage')
$model_name = J $data @('model','display_name')
if (-not $model_name) { $model_name = J $data @('model','id') }
$cost_usd   = J $data @('cost','total_cost_usd')
$cwd        = J $data @('workspace','current_dir')
if (-not $cwd) { $cwd = J $data @('cwd') }
$session_id = J $data @('session_id')

$HOMEDIR = $env:USERPROFILE
$ccfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOMEDIR '.claude' }

# notes: 2026-08-23 停用自動交接。三次觸發都只剩 5~20 分鐘就重置，等重置比換 Codex 劃算。
#        機制、guard 與 /tocodex 完整保留，要恢復把旗標改回 $true。
$HANDOFF_ON = $false

# --- 90% 手動交接守門員（背景執行，不擋 status line）---
# notes: 走暫存檔而非直接 pipe 到 StandardInput。PS 5.1 的 Process.StandardInput 會在開頭多塞
#        一個 UTF-8 BOM，python 的 json.load 會當場炸掉（PS 7 已修掉）。要改 pipe 得等只支援 7+。
# notes: 90% 門檻在這裡先擋一次（guard 自己也會擋）。不然沒到門檻也要 spawn 一個 python，
#        statusline 一分鐘刷十幾次就是十幾個 process。兩邊都要改門檻時記得一起改。
$guard = Join-Path $HOMEDIR '.claude\scripts\quota-handoff-guard.py'
if ($HANDOFF_ON -and $session_id -and (Test-Path $guard) -and ($null -ne $five_pct) -and ([int][double]$five_pct -ge 90)) {
  try {
    # 檔名綁 session_id：同一 session 每次刷新覆寫同一個檔，不會每刷一次留一個
    $tmp = Join-Path $env:TEMP "csl-guard-$session_id.json"
    [IO.File]::WriteAllText($tmp, $raw)
    Start-Process -FilePath 'python' -ArgumentList "`"$guard`"" `
      -RedirectStandardInput $tmp -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    # 清掉舊 session 的殘檔；1 小時前的檔不可能還有 python 在讀
    Get-ChildItem $env:TEMP -Filter 'csl-guard-*.json' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } catch {}
}

# --- 剩餘 ctx / 5h ---
$ctx_rem  = if ($null -ne $ctx_used) { [int][math]::Round(100 - [double]$ctx_used) } else { $null }

# --- 本 session 的 API 花費 ---
# notes: 這是 CC 自己回報的累計金額，訂閱制下也照算，不等於帳單上真的被收的錢。
$cost_str = ''
if ($null -ne $cost_usd) { $cost_str = '{0:F2}' -f [double]$cost_usd }

# --- 專案名稱 ---
$dir_display = if ($cwd) { Split-Path $cwd -Leaf } else { '' }

# --- 當前時間 ---
$now = Get-Date -Format 'HH:mm'
$now_epoch = [DateTimeOffset]::Now.ToUnixTimeSeconds()

# --- 重置時間格式 ---
function Fmt-Reset($epoch) {
  if (-not $epoch) { return '' }
  try { return [DateTimeOffset]::FromUnixTimeSeconds([long][double]$epoch).ToLocalTime().ToString('HH:mm') } catch { return '' }
}
function Fmt-ResetDate($epoch) {
  if (-not $epoch) { return '' }
  try { return [DateTimeOffset]::FromUnixTimeSeconds([long][double]$epoch).ToLocalTime().ToString('M/d HH:mm') } catch { return '' }
}
$five_next = Fmt-Reset $five_reset

# --- 顏色 ---
$E    = [char]27
$CYAN = "$E[0;36m"; $YEL = "$E[0;33m"; $GRN = "$E[0;32m"; $RED = "$E[0;31m"
$DIM  = "$E[2m";    $RST = "$E[0m"
$TC_GRN = "$E[38;2;80;200;81m"
$TC_YEL = "$E[38;2;255;235;59m"
$TC_OG  = "$E[38;2;255;152;0m"
$TC_RD  = "$E[38;2;244;67;54m"

function Color-Used($v) {
  $v = [int][double]$v
  if ($v -ge 80) { $RED } elseif ($v -ge 50) { $YEL } else { $GRN }
}
function Color-Rem($v) {
  $v = [int][double]$v
  if ($v -le 20) { $RED } elseif ($v -le 50) { $YEL } else { $GRN }
}

# --- 時間進度條：實心=已過時間 ---
$FULL = [string][char]0x2588   # █
$LIGHT = [string][char]0x2591  # ░
function Time-Bar([long]$reset_ep, [long]$window, [int]$W = 8) {
  $remaining = $reset_ep - $now_epoch
  if ($remaining -lt 0) { $remaining = 0 }
  if ($remaining -gt $window) { $remaining = $window }
  $elapsed = $window - $remaining
  $filled = [int][math]::Round($elapsed / $window * $W)
  if ($filled -gt $W) { $filled = $W }
  ($FULL * $filled) + ($LIGHT * ($W - $filled))
}

# --- 5h + 7d 額度 ---
$quota_block = ''
$five_reset_i = if ($five_reset) { [long][double]$five_reset } else { 0 }
$week_reset_i = if ($week_reset) { [long][double]$week_reset } else { 0 }

if ($null -ne $five_pct) {
  if (($five_reset_i -gt 0) -and ($now_epoch -ge $five_reset_i)) {
    $quota_block += "${DIM}5h$RST $GRN$([char]0x21BB)$RST"
  } else {
    $vi = [int][double]$five_pct
    $bar = if ($five_reset_i -gt 0) { Time-Bar $five_reset_i 18000 8 } else { '' }
    $quota_block += "${DIM}5h$RST "
    if ($bar) { $quota_block += "$DIM$bar$RST " }
    $quota_block += "$(Color-Used $vi)$vi%$RST"
    if ($five_next) { $quota_block += " $DIM$([char]0x2192)$five_next$RST" }
  }
}

if ($null -ne $week_pct) {
  $wi = [int][double]$week_pct
  $wbar = if ($week_reset_i -gt 0) { Time-Bar $week_reset_i 604800 8 } else { '' }
  $wnext = Fmt-ResetDate $week_reset
  if ($quota_block) { $quota_block += '  ' }
  $quota_block += "${DIM}7d$RST "
  if ($wbar) { $quota_block += "$DIM$wbar$RST " }
  $quota_block += "$(Color-Used $wi)$wi%$RST"
  if ($wnext) { $quota_block += " $DIM$([char]0x2192)$wnext$RST" }
}

# usage credits（overage）：JSON 有這段才顯示
# notes: CC 2.1.226 的 statusline payload 只吐 five_hour / seven_day，overage 目前不會出現；
#        欄位一旦開放就會自動顯示，沒有就整段跳過。
if ($null -ne $ovr_pct) {
  $oi = [int][double]$ovr_pct
  if ($quota_block) { $quota_block += '  ' }
  $quota_block += "${DIM}credits$RST $(Color-Used $oi)$oi%$RST"
}

# --- 12 格 4 色漸層 context bar（保留備用）---
function Bar12-Gradient($used_pct) {
  if ($null -eq $used_pct) { return '' }
  $used = [int][double]$used_pct
  $W = 12
  $filled = [int][math]::Floor($used * $W / 100)
  if ($filled -gt $W) { $filled = $W }
  $z1 = 3; $z2 = 6; $z3 = 9
  $b = ''
  for ($i = 0; $i -lt $W; $i++) {
    if ($i -lt $filled) {
      if     ($i -lt $z1) { $b += "$TC_GRN$FULL" }
      elseif ($i -lt $z2) { $b += "$TC_YEL$FULL" }
      elseif ($i -lt $z3) { $b += "$TC_OG$FULL" }
      else                { $b += "$TC_RD$FULL" }
    } else { $b += "$DIM$LIGHT" }
  }
  "$b$RST"
}

# --- 終端寬度 ---
$cols = 120
if ($env:COLUMNS) { $cols = [int]$env:COLUMNS }
else { try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -gt 0) { $cols = $w } } catch {} }

# Git 指令需在專案目錄下執行
if ($cwd -and (Test-Path $cwd)) { try { Set-Location $cwd } catch {} }

# ============================================================
# 寬模式（>= 80 cols）— 雙行
# ============================================================
if ($cols -ge 80) {
  $L1 = "$DIM$now$RST  $CYAN$dir_display$RST"
  if ($model_name) {
    $model_str = $model_name
    if ($effort) { $model_str += [string][char]0xB7 + $effort }
    $L1 += "  $DIM[$model_str]$RST"
  }
  if ($null -ne $ctx_rem) {
    $c = Color-Rem $ctx_rem
    $L1 += "  ${DIM}ctx$RST $c$ctx_rem%$RST"
  }
  if ($cost_str) { $L1 += "  $DIM$([char]0x24)$cost_str$RST" }
  if ($quota_block) { $L1 += "    $quota_block" }
  if ($HANDOFF_ON -and ($null -ne $five_pct) -and ([int][double]$five_pct -ge 90)) {
    $L1 += "  $RED$([char]0x26A0) 交給Codex$RST"
  }
  Write-Output $L1

  # ── L2 ──
  $L2 = ''

  # 最後訊息（per-session）
  if ($session_id) {
    $msg_file = Join-Path $HOMEDIR ".claude\last-session-msg-$session_id"
    if (Test-Path $msg_file) {
      $last_msg = (Get-Content $msg_file -Raw -ErrorAction SilentlyContinue)
      if ($last_msg) { $L2 = "$DIM$([char]::ConvertFromUtf32(0x1F4DD)) $($last_msg.Trim())$RST" }
    }
  }

  # Git 分支 + dirty + 增刪
  $git_top = git rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -eq 0 -and $git_top) {
    $br = git branch --show-current 2>$null
    if ($br) {
      git diff-index --quiet HEAD -- 2>$null
      $dirty = if ($LASTEXITCODE -ne 0) { '*' } else { '' }
      if (-not $dirty) {
        $untracked = git ls-files --others --exclude-standard 2>$null | Select-Object -First 1
        if ($untracked) { $dirty = '*' }
      }
      $git_block = "$CYAN$([char]0x2387) $br$dirty$RST"

      $stat = git diff --shortstat HEAD 2>$null
      $ins = $null; $del = $null
      if ($stat -match '(\d+) insertion') { $ins = $Matches[1] }
      if ($stat -match '(\d+) deletion')  { $del = $Matches[1] }
      if ($ins -or $del) {
        $diff_str = ''
        if ($ins) { $diff_str += "$GRN+$ins$RST" }
        if ($ins -and $del) { $diff_str += "$DIM/$RST" }
        if ($del) { $diff_str += "$RED-$del$RST" }
        $git_block += " $diff_str"
      }
      $L2 = if ($L2) { "$L2  $git_block" } else { $git_block }
    }
  }

  # Codex job status（如有 codex-statusline.ps1）
  $codex_script = Join-Path $ccfg 'scripts\codex-statusline.ps1'
  if (Test-Path $codex_script) {
    $codex_info = & $codex_script 2>$null
    if ($codex_info) {
      $ci = "$DIM$codex_info$RST"
      $L2 = if ($L2) { "$L2  $ci" } else { $ci }
    }
  }

  if ($L2) { Write-Output $L2 }

# ============================================================
# 窄模式（< 80 cols）— 單行精簡
# ============================================================
} else {
  $L = "$DIM$now$RST $CYAN$dir_display$RST"
  if ($null -ne $ctx_rem) { $L += " ${DIM}ctx$RST$(Color-Rem $ctx_rem)$ctx_rem%$RST" }
  if ($cost_str) { $L += " $DIM$([char]0x24)$cost_str$RST" }
  if ($five_next) { $L += " $DIM$([char]0x2192)$five_next$RST" }
  if ($quota_block) { $L += " $quota_block" }
  if ($HANDOFF_ON -and ($null -ne $five_pct) -and ([int][double]$five_pct -ge 90)) { $L += " $RED!$RST" }
  Write-Output $L
}
