# deploy.ps1 —— 导出 CSV 后手动跑一次，把最新数据推到 GitHub
# 用法：导出当天 CSV 到本文件夹后，双击本脚本（或在此目录运行）
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$csv  = Join-Path $PSScriptRoot "招聘信息源.csv"
$json = Join-Path $PSScriptRoot "campus-hiring.json"

# 1) 重新生成 JSON
& python csv_to_json.py $csv $json
if ($LASTEXITCODE -ne 0) { throw "csv_to_json.py 执行失败" }

# 2) 仅在有变化时提交并推送（重复运行不会报错）
git add $json
$changed = git status --porcelain $json
if ($changed) {
    $date = Get-Date -Format "yyyy-MM-dd"
    git commit -m "daily update $date"
    git push origin main   # 分支名按你仓库实际改：main / master
    Write-Host "已推送 $date 的招聘数据到 GitHub"
} else {
    Write-Host "JSON 无变化，跳过推送"
}
