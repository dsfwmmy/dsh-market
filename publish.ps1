# publish.ps1 —— 工作区 → Git 市场 → CDN 的一条龙发布
# 链路：D:/Jarvis/workspace/dsh-market-site (仓库工作副本) ← E:\dsh-market-safe-fixed\market (市场包) → GitHub → jsDelivr
# 用法：powershell -ExecutionPolicy Bypass -File publish.ps1 [-SkipGates] [-Message "index: ..."]
param(
  [switch]$SkipGates,
  [string]$Message = ''
)
$ErrorActionPreference = 'Continue'
$nl = [char]10
$pkg   = 'E:/dsh-market-safe-fixed/market'
$repo  = 'D:/Jarvis/workspace/dsh-market-site'
$owner = 'dsfwmmy'
$name  = 'dsh-market'
$cdn   = "https://cdn.jsdelivr.net/gh/$owner/$name@main/index.json"

function Fail($msg) { Write-Host "ABORT $msg" -ForegroundColor Red; exit 1 }

# ① 三道闸门（任何一道不绿就不发布）
if (-not $SkipGates) {
  Push-Location $pkg
  node seed-index.mjs | Out-Null
  node apply-patches.mjs | Out-Null
  $t = node test.cjs 2>&1 | Out-String
  if ($t -notmatch '11 passed / 0 failed') { Pop-Location; Fail "test.cjs 未全绿：" + ($t -split $nl | Select-Object -Last 3) }
  $s = node smoke.mjs 2>&1 | Out-String
  if ($s -notmatch '6 passed / 0 failed') { Pop-Location; Fail "smoke.mjs 未全绿：" + ($s -split $nl | Select-Object -Last 3) }
  Pop-Location
  Write-Host "gates: 11/11 + 6/6 OK"
}

# ② 同步产物进仓库
Copy-Item (Join-Path $pkg 'site/index.json') $repo -Force
Copy-Item (Join-Path $pkg 'site/icons') $repo -Recurse -Force
$hash = (Get-FileHash (Join-Path $repo 'index.json') -Algorithm SHA256).Hash.Substring(0, 12)
Write-Host "index sha256[$hash]"

# ③ 提交并推送（token 只在这条命令里出现）
$secret = ((@('protocol=https', 'host=github.com', '') -join $nl) + $nl) | git credential fill 2>$null
$tok = ($secret | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
if (-not $tok) { Fail '拿不到 GitHub 凭据（git credential fill 为空）' }
Push-Location $repo
git add -A
if (git status --porcelain) {
  if (-not $Message) { $Message = "index: publish $hash" }
  git commit -m $Message | Out-Null
  Write-Host "commit: $Message"
} else {
  Write-Host "commit: 无变化"
}
git push --force "https://$($owner):$tok@github.com/$($owner)/$name.git" main 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "git push 失败（exit $LASTEXITCODE）" }
Pop-Location
Write-Host "push: done"

# ④ 清 jsDelivr 缓存，否则 @main 最长 12 小时仍是旧索引
try { Invoke-RestMethod "https://purge.jsdelivr.net/gh/$owner/$name@main/index.json" -TimeoutSec 20 | Out-Null; Write-Host "purge: sent" }
catch { Write-Host "purge: 失败（$($_.Exception.Message)），CDN 可能仍是旧内容" -ForegroundColor Yellow }

# ⑤ 回读确认 CDN 上是这份
Start-Sleep -Seconds 2
try {
  $j = Invoke-RestMethod $cdn -TimeoutSec 20 -Headers @{ 'Cache-Control' = 'no-cache' }
  $remote = ($j.plugins | ForEach-Object { $_.name }) -join ','
  Write-Host "cdn: plugins=$($j.plugins.Count) title=$($j.title.zh) [$remote]"
} catch {
  Write-Host "cdn: 回读失败 $($_.Exception.Message)" -ForegroundColor Yellow
}
