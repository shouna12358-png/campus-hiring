# Generate campus-hiring.json and publish it to GitHub Pages.
# Run from PowerShell after replacing the source CSV:
#   .\deploy.ps1
# To publish a processed CSV explicitly:
#   .\deploy.ps1 -SourceCsv "招聘信息源_已匹配500强标签_超多hc_更新匹配.csv"
# To validate conversion without pushing:
#   .\deploy.ps1 -SourceCsv "招聘信息源_已匹配500强标签_超多hc_更新匹配.csv" -SkipPush
# If GitHub is unreachable, you can override the proxy for this run:
#   $env:CAMPUS_GIT_PROXY = "http://127.0.0.1:7890"
#   .\deploy.ps1

[CmdletBinding()]
param(
    [string]$GitProxy = "",
    [string]$SourceCsv = "",
    [switch]$SkipPush
)

$ErrorActionPreference = "Stop"
$env:GIT_TERMINAL_PROMPT = "0"
Set-Location -LiteralPath $PSScriptRoot

$converter = Join-Path $PSScriptRoot "csv_to_json.py"
$jsonPath = Join-Path $PSScriptRoot "campus-hiring.json"
# By default keep the original source filename. When a processed copy is ready,
# pass -SourceCsv with a filename or an absolute path so deployment cannot
# silently publish a different CSV than the one just reviewed.
if ($SourceCsv) {
    if ([System.IO.Path]::IsPathRooted($SourceCsv)) {
        $csvPath = $SourceCsv
    } else {
        $csvPath = Join-Path $PSScriptRoot $SourceCsv
    }
} else {
    # Build the default source filename from Unicode code points so this script
    # also works when launched by Windows PowerShell 5.1.
    $csvName = (-join @(
        [char]0x62DB, [char]0x8058, [char]0x4FE1, [char]0x606F, [char]0x6E90
    )) + ".csv"
    $csvPath = Join-Path $PSScriptRoot $csvName
}
$csvPath = [System.IO.Path]::GetFullPath($csvPath)

if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
    throw "Source CSV was not found: $csvPath"
}
if (-not (Test-Path -LiteralPath $converter)) {
    throw "Missing converter: $converter"
}

Write-Host "Generating JSON from: $(Split-Path -Leaf $csvPath)"

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

if ($SkipPush) {
    Write-Host "Conversion validation completed; GitHub push skipped." -ForegroundColor Cyan
    exit 0
}

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
        if (-not $async.AsyncWaitHandle.WaitOne(1000)) {
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
    $gitArgs = @($gitBase)
    if ($Proxy) {
        Write-Host "Pushing to GitHub through proxy $Proxy."
        $gitArgs += @(
            "-c", "http.proxy=$Proxy",
            "-c", "https.proxy=$Proxy",
            "-c", "http.version=HTTP/1.1"
        )
    } else {
        Write-Host "No local proxy detected; pushing directly to GitHub."
    }
    $gitArgs += @("push", "--porcelain", "origin", "main")
    $gitOutput = & git @gitArgs 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($gitOutput)) {
        Write-Host $line
    }
    return $exitCode
}

function Get-RemoteMainSha([string]$Proxy) {
    $gitArgs = @($gitBase)
    if ($Proxy) {
        $gitArgs += @(
            "-c", "http.proxy=$Proxy",
            "-c", "https.proxy=$Proxy",
            "-c", "http.version=HTTP/1.1"
        )
    }
    $remoteOutput = & git @gitArgs ls-remote origin refs/heads/main 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or -not $remoteOutput) {
        return ""
    }
    $firstLine = @($remoteOutput)[0].ToString()
    return (($firstLine -split "\s+")[0]).Trim()
}

$localMainSha = (& git @gitBase rev-parse HEAD).Trim()
$verified = $false
$pushExit = 1
$remoteMainSha = ""

# Network proxies can accept read requests while intermittently failing on push.
# Retry the same push and verify the remote branch after every successful exit.
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host "GitHub push attempt $attempt/3."
    $pushExit = Invoke-GitPush $GitProxy
    if ($pushExit -eq 0) {
        $remoteMainSha = Get-RemoteMainSha $GitProxy
        if ($remoteMainSha -eq $localMainSha) {
            $verified = $true
            break
        }
        Write-Host "Push returned success, but remote main is still $remoteMainSha; retrying." -ForegroundColor Yellow
    }
    if ($attempt -lt 3) {
        Start-Sleep -Seconds 3
    }
}

# If a proxy was selected but all proxy attempts failed, make one direct retry.
if (-not $verified -and $GitProxy) {
    Write-Host "Proxy push did not verify; retrying once without a proxy..." -ForegroundColor Yellow
    $pushExit = Invoke-GitPush ""
    if ($pushExit -eq 0) {
        $remoteMainSha = Get-RemoteMainSha ""
        $verified = ($remoteMainSha -eq $localMainSha)
    }
}

if (-not $verified) {
    Write-Host "Push failed or remote verification failed. The local commit was kept and can be retried safely." -ForegroundColor Red
    Write-Host 'Set $env:CAMPUS_GIT_PROXY="http://127.0.0.1:7890" before retrying if GitHub is blocked on this network.' -ForegroundColor Yellow
    throw "git push was not verified: local=$localMainSha remote=$remoteMainSha exit=$pushExit"
}

Write-Host "GitHub updated successfully." -ForegroundColor Green
Write-Host "GitHub Pages may need 1-3 minutes to publish the new JSON." -ForegroundColor Cyan
Write-Host "JSON endpoint: https://shouna12358-png.github.io/campus-hiring/campus-hiring.json" -ForegroundColor Cyan
