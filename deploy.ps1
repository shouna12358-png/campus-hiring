# Generate campus-hiring.json and publish it to GitHub Pages.
# Run from PowerShell after replacing the source CSV:
#   .\deploy.ps1
# If GitHub is unreachable, you can override the proxy for this run:
#   $env:CAMPUS_GIT_PROXY = "http://127.0.0.1:7890"
#   .\deploy.ps1

[CmdletBinding()]
param(
    [string]$GitProxy = ""
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

$converter = Join-Path $PSScriptRoot "csv_to_json.py"
$jsonPath = Join-Path $PSScriptRoot "campus-hiring.json"
$csvFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.csv" -File)

if ($csvFiles.Count -eq 0) {
    throw "No CSV file was found in $PSScriptRoot"
}
if ($csvFiles.Count -gt 1) {
    throw "More than one CSV file was found. Keep only the source CSV in this folder."
}
if (-not (Test-Path -LiteralPath $converter)) {
    throw "Missing converter: $converter"
}

$csvPath = $csvFiles[0].FullName
Write-Host "Generating JSON from: $($csvFiles[0].Name)"

$python = Get-Command python.exe -ErrorAction SilentlyContinue
$pythonPrefix = @()
if (-not $python) {
    $python = Get-Command py.exe -ErrorAction SilentlyContinue
    $pythonPrefix = @("-3")
}
if (-not $python) {
    throw "Python was not found. Install Python or add it to PATH."
}

& $python.Source @pythonPrefix $converter $csvPath $jsonPath
if ($LASTEXITCODE -ne 0) {
    throw "csv_to_json.py failed with exit code $LASTEXITCODE"
}

# Validate the generated file before touching Git.
try {
    $payload = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "Generated JSON is invalid: $($_.Exception.Message)"
}

$itemCount = @($payload.items).Count
if ($itemCount -eq 0 -or [int]$payload.count -ne $itemCount) {
    throw "Generated JSON failed validation: count=$($payload.count), items=$itemCount"
}
Write-Host "JSON validated: $itemCount records; updatedAt=$($payload.updatedAt)" -ForegroundColor Green

$gitBase = @(
    "-C", $PSScriptRoot,
    "-c", "safe.directory=$PSScriptRoot"
)

# Stage only the generated JSON. Source CSV and other local files are not committed.
& git @gitBase add -- "campus-hiring.json"
if ($LASTEXITCODE -ne 0) {
    throw "git add failed"
}

# A failed push leaves the commit locally. Therefore, even when the JSON has not
# changed, this script still continues to push any previous unpushed commit.
& git @gitBase diff --cached --quiet -- "campus-hiring.json"
$stagedDiffExit = $LASTEXITCODE
if ($stagedDiffExit -eq 1) {
    $date = Get-Date -Format "yyyy-MM-dd"
    & git @gitBase commit --only -m "daily update $date" -- "campus-hiring.json"
    if ($LASTEXITCODE -ne 0) {
        throw "git commit failed"
    }
    Write-Host "Created local commit for $date"
} elseif ($stagedDiffExit -ne 0) {
    throw "Unable to inspect staged changes"
} else {
    Write-Host "JSON content is unchanged; checking for unpushed commits."
}

function Test-LocalTcpPort([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(250)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Find-GitProxy {
    if ($env:CAMPUS_GIT_PROXY) { return $env:CAMPUS_GIT_PROXY }

    # Common local Clash ports. The first open port is used only for this push.
    foreach ($port in @(7890, 7897, 1080)) {
        if (Test-LocalTcpPort $port) {
            return "http://127.0.0.1:$port"
        }
    }

    if ($env:HTTPS_PROXY) { return $env:HTTPS_PROXY }
    if ($env:HTTP_PROXY) { return $env:HTTP_PROXY }
    return ""
}

if (-not $GitProxy) {
    $GitProxy = Find-GitProxy
}

function Invoke-GitPush([string]$Proxy) {
    if ($Proxy) {
        Write-Host "Pushing to GitHub through the detected proxy."
        & git @gitBase -c "http.proxy=$Proxy" -c "https.proxy=$Proxy" -c "http.version=HTTP/1.1" push origin main
    } else {
        Write-Host "No local proxy detected; pushing directly to GitHub."
        & git @gitBase push origin main
    }
    return $LASTEXITCODE
}

$pushExit = Invoke-GitPush $GitProxy

# If the preferred proxy failed, make one direct retry. This handles networks
# where GitHub is reachable directly but a stale local proxy is not.
if ($pushExit -ne 0 -and $GitProxy) {
    Write-Host "Proxy push failed; retrying once without a proxy..." -ForegroundColor Yellow
    $pushExit = Invoke-GitPush ""
}

if ($pushExit -ne 0) {
    Write-Host "Push failed. The local commit was kept and can be retried safely." -ForegroundColor Red
    Write-Host 'If GitHub is blocked on this network, run: $env:CAMPUS_GIT_PROXY="http://127.0.0.1:7890"' -ForegroundColor Yellow
    throw "git push failed with exit code $pushExit"
}

Write-Host "GitHub updated successfully." -ForegroundColor Green
Write-Host "GitHub Pages may need 1-3 minutes to publish the new JSON." -ForegroundColor Cyan
Write-Host "JSON endpoint: https://shouna12358-png.github.io/campus-hiring/campus-hiring.json" -ForegroundColor Cyan
