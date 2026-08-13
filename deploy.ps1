# deploy.ps1 —— 导出 CSV 后手动跑一次，把最新数据推到 GitHub
# 用法：导出当天 CSV 到本文件夹后，双击本脚本（或右键→使用 PowerShell 运行）
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$csv  = Join-Path $PSScriptRoot "招聘信息源.csv"
$json = Join-Path $PSScriptRoot "campus-hiring.json"

# 1) 重新生成 JSON
Write-Host "正在把 $csv 转换为 $json ..."
& python csv_to_json.py $csv $json
if ($LASTEXITCODE -ne 0) { throw "csv_to_json.py 执行失败" }

# 显示生成后的更新时间
$jsonUpdatedAt = (Get-Content $json -Raw | ConvertFrom-Json).updatedAt
Write-Host "JSON 生成完成，更新时间戳：$jsonUpdatedAt"

# 2) 提交并推送（仅在有变化时）
git add $json

# 用 git diff --cached 判断暂存区是否真的有变化
& git diff --cached --quiet $json
if ($LASTEXITCODE -eq 0) {
    Write-Host "campus-hiring.json 没有变化，跳过推送" -ForegroundColor Yellow
    exit 0
}

$date = Get-Date -Format "yyyy-MM-dd"
git commit -m "daily update $date"
if ($LASTEXITCODE -ne 0) { throw "git commit 失败" }

git push origin main
if ($LASTEXITCODE -ne 0) { throw "git push 失败" }

Write-Host "已推送 $date 的招聘数据到 GitHub" -ForegroundColor Green
Write-Host "约 1–2 分钟后，Pages 会刷新；完整数据地址："
Write-Host "https://shouna12358-png.github.io/campus-hiring/campus-hiring.json" -ForegroundColor Cyan
