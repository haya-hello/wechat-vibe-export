param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$ToolRoot,
    [Parameter(Mandatory)][string]$WeChatStorage,
    [Parameter(Mandatory)][string]$AccountId,
    [Parameter(Mandatory)][string]$TargetLabel,
    [Parameter(Mandatory)][string]$ExtractScript,
    [Parameter(Mandatory)][string]$OutputEnvironmentVariable,
    [string]$KeyPath = "",
    [string]$PythonExecutable = "",
    [string]$DecryptModulePath = "",
    [switch]$ForceRefresh,
    [switch]$ForceExport
)

$ErrorActionPreference = "Stop"
$workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$toolRootResolved = (Resolve-Path -LiteralPath $ToolRoot).Path
$storageResolved = (Resolve-Path -LiteralPath $WeChatStorage).Path
$outputsRoot = Join-Path $workspace "outputs"
$statePath = Join-Path $outputsRoot "wechat_refresh_state.json"
$today = Get-Date -Format "yyyyMMdd"
if ([string]::IsNullOrWhiteSpace($KeyPath)) { $KeyPath = Join-Path $outputsRoot "db_key.json" }
if ([string]::IsNullOrWhiteSpace($PythonExecutable)) { $PythonExecutable = Join-Path $toolRootResolved ".venv\Scripts\python.exe" }
if ([string]::IsNullOrWhiteSpace($DecryptModulePath)) { $DecryptModulePath = Join-Path $toolRootResolved "vendor\WeChatDataAnalysis-selected\src" }
$keyResolved = (Resolve-Path -LiteralPath $KeyPath).Path
$python = (Resolve-Path -LiteralPath $PythonExecutable).Path
$decryptModuleResolved = (Resolve-Path -LiteralPath $DecryptModulePath).Path
$extractScriptPath = if ([System.IO.Path]::IsPathRooted($ExtractScript)) { $ExtractScript } else { Join-Path $workspace $ExtractScript }
$extractScriptPath = (Resolve-Path -LiteralPath $extractScriptPath).Path
New-Item -ItemType Directory -Force -Path $outputsRoot | Out-Null

$refreshMutex = [System.Threading.Mutex]::new($false, "Local\WeChatVibeExportRefresh")
$refreshMutexAcquired = $false
try { $refreshMutexAcquired = $refreshMutex.WaitOne([System.TimeSpan]::FromSeconds(60)) }
catch [System.Threading.AbandonedMutexException] { $refreshMutexAcquired = $true }
if (!$refreshMutexAcquired) { $refreshMutex.Dispose(); throw "Timed out waiting for another WeChat refresh process to finish." }
trap {
    if ($refreshMutexAcquired) { $refreshMutex.ReleaseMutex(); $refreshMutexAcquired = $false }
    $refreshMutex.Dispose()
    throw
}

function Get-SharedFileSha256 {
    param([string]$Path)
    # 中文：以共享只读方式访问 WAL，避免中断正在运行的微信。
    # English: Open WAL files shared-read so the running client is not interrupted.
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($hasher.ComputeHash($stream))).Replace("-", "").ToLowerInvariant() }
    finally { $hasher.Dispose(); $stream.Dispose() }
}

function Get-SourceSnapshot {
    param([string]$StorageRoot)
    $relativePaths = @(
        "contact\contact.db", "contact\contact.db-wal",
        "message\message_0.db", "message\message_0.db-wal",
        "message\media_0.db", "message\media_0.db-wal",
        "message\message_resource.db", "message\message_resource.db-wal"
    )
    $files = @()
    foreach ($relativePath in $relativePaths) {
        $path = Join-Path $StorageRoot $relativePath
        if (!(Test-Path -LiteralPath $path)) { $files += [ordered]@{ relative_path = $relativePath; exists = $false }; continue }
        $item = Get-Item -LiteralPath $path
        $entry = [ordered]@{ relative_path = $relativePath; exists = $true; length = [int64]$item.Length; last_write_utc = $item.LastWriteTimeUtc.ToString("o") }
        if ($relativePath.EndsWith("-wal", [System.StringComparison]::OrdinalIgnoreCase)) { $entry.sha256 = Get-SharedFileSha256 -Path $path }
        $files += $entry
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($files | ConvertTo-Json -Depth 4 -Compress))
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { $signature = ([System.BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $hasher.Dispose() }
    return [ordered]@{ signature = $signature; files = $files }
}

function Read-State {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json }
    catch { Write-Warning "Ignoring unreadable refresh state: $Path"; return $null }
}

function Write-State {
    param([string]$Path, $State)
    $temporaryPath = "$Path.tmp"
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Test-DecryptedSnapshot {
    param([string]$DatabaseBase)
    if ([string]::IsNullOrWhiteSpace($DatabaseBase) -or !(Test-Path -LiteralPath $DatabaseBase)) { return $false }
    foreach ($name in @("contact.db", "message_0.db", "media_0.db", "message_resource.db")) {
        $path = Join-Path $DatabaseBase $name
        if (!(Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -le 0) { return $false }
    }
    return $true
}

$startedAt = Get-Date
$source = Get-SourceSnapshot -StorageRoot $storageResolved
$previousState = Read-State -Path $statePath
$previousSignature = if ($null -ne $previousState) { [string]$previousState.source_signature } else { "" }
$previousDbBase = if ($null -ne $previousState) { [string]$previousState.database_base } else { "" }
$snapshotReusable = !$ForceRefresh -and $source.signature -eq $previousSignature -and (Test-DecryptedSnapshot -DatabaseBase $previousDbBase)

if ($snapshotReusable) {
    $decryptOut = [string]$previousState.decrypted_output; $dbBase = $previousDbBase; $decryptAction = "reused"
} else {
    $decryptOut = Join-Path $outputsRoot "decrypted_current_$today"
    $dbBase = Join-Path $decryptOut "databases\$AccountId"
    New-Item -ItemType Directory -Force -Path $decryptOut | Out-Null
    $env:PYTHONIOENCODING = "utf-8"; $env:WECHAT_TOOL_OUTPUT_DIR = $decryptOut; $env:WECHAT_DATA_ROOT = $workspace; $env:WECHAT_STORAGE_ROOT = $storageResolved
    $env:WECHAT_TOOL_ENABLE_CONSOLE_LOG = "0"; $env:WECHAT_DECRYPT_MODULE_PATH = $decryptModuleResolved; $env:WECHAT_KEY_PATH = $keyResolved
    Push-Location $toolRootResolved
    try {
@'
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.environ["WECHAT_DECRYPT_MODULE_PATH"])
from wechat_decrypt_tool.wechat_decrypt import decrypt_wechat_databases

key_file = Path(os.environ["WECHAT_KEY_PATH"])
key_data = json.loads(key_file.read_text(encoding="utf-8"))
key = key_data.get("key") or key_data.get("db_key") or key_data.get("hex_key")
if not key:
    raise SystemExit(f"No key found in {key_file}")
result = decrypt_wechat_databases(os.environ["WECHAT_STORAGE_ROOT"], key)
print(json.dumps({k: result.get(k) for k in ("status", "message", "success_count", "total_databases")}, ensure_ascii=False))
'@ | & $python -
        if ($LASTEXITCODE -ne 0) { throw "WeChat database decryption failed with exit code $LASTEXITCODE" }
    } finally { Pop-Location }
    if (!(Test-DecryptedSnapshot -DatabaseBase $dbBase)) { throw "Decryption completed without all required databases: $dbBase" }
    $decryptAction = "refreshed"
}

$exports = @{}
if ($null -ne $previousState -and $null -ne $previousState.exports) { foreach ($property in $previousState.exports.PSObject.Properties) { $exports[$property.Name] = $property.Value } }
$extractScriptItem = Get-Item -LiteralPath $extractScriptPath
$exportKey = "$TargetLabel|$($extractScriptItem.FullName.ToLowerInvariant())"
$previousExport = if ($exports.ContainsKey($exportKey)) { $exports[$exportKey] } else { $null }
$previousExportMarker = if ($null -ne $previousExport) { Join-Path ([string]$previousExport.output_dir) "${TargetLabel}_messages.json" } else { "" }
$exportReusable = !$ForceExport -and $null -ne $previousExport -and [string]$previousExport.source_signature -eq $source.signature -and [int64]$previousExport.script_length -eq [int64]$extractScriptItem.Length -and [string]$previousExport.script_last_write_utc -eq $extractScriptItem.LastWriteTimeUtc.ToString("o") -and ![string]::IsNullOrWhiteSpace($previousExportMarker) -and (Test-Path -LiteralPath $previousExportMarker)

if ($exportReusable) {
    $exportOut = [string]$previousExport.output_dir; $exportAction = "reused"
} else {
    $exportOut = Join-Path $outputsRoot "${TargetLabel}_export_$today"
    $env:WECHAT_DECRYPTED_BASE = $dbBase
    [Environment]::SetEnvironmentVariable($OutputEnvironmentVariable, $exportOut, "Process")
    $env:WECHAT_VOICE_CACHE_DIR = Join-Path $outputsRoot "wechat_voice_cache\$TargetLabel"
    Push-Location $workspace
    try { & $python $extractScriptPath; if ($LASTEXITCODE -ne 0) { throw "Conversation export failed with exit code $LASTEXITCODE" } }
    finally { Pop-Location }
    $exportMarker = Join-Path $exportOut "${TargetLabel}_messages.json"
    if (!(Test-Path -LiteralPath $exportMarker)) { throw "Conversation export did not create its marker file: $exportMarker" }
    $exportAction = "refreshed"
    $exports[$exportKey] = [ordered]@{ target_label = $TargetLabel; source_signature = $source.signature; script_path = $extractScriptItem.FullName; script_length = [int64]$extractScriptItem.Length; script_last_write_utc = $extractScriptItem.LastWriteTimeUtc.ToString("o"); output_dir = $exportOut; completed_at = (Get-Date).ToString("o") }
}

Write-State -Path $statePath -State ([ordered]@{ version = 1; updated_at = (Get-Date).ToString("o"); source_signature = $source.signature; source_files = $source.files; decrypted_output = $decryptOut; database_base = $dbBase; exports = $exports })
[pscustomobject]@{ source_signature = $source.signature; decrypt_action = $decryptAction; export_action = $exportAction; decrypted_output = $decryptOut; database_base = $dbBase; export_output = $exportOut; state_path = $statePath; elapsed_seconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2) } | ConvertTo-Json -Depth 4
if ($refreshMutexAcquired) { $refreshMutex.ReleaseMutex(); $refreshMutexAcquired = $false }
$refreshMutex.Dispose()
