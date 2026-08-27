param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$WeChatFilesRoot,
    [Parameter(Mandatory)][string]$AccountFolder,
    [switch]$CompareState
)

$ErrorActionPreference = "Stop"

function Resolve-IfExists {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path -LiteralPath $Path)) { return $null }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Read-State {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Get-LightFileEntry {
    param([string]$StorageRoot, [string]$RelativePath)
    $path = Join-Path $StorageRoot $RelativePath
    if (!(Test-Path -LiteralPath $path)) { return [ordered]@{ relative_path = $RelativePath; exists = $false } }
    $item = Get-Item -LiteralPath $path
    return [ordered]@{ relative_path = $RelativePath; exists = $true; length = [int64]$item.Length; last_write_utc = $item.LastWriteTimeUtc.ToString("o") }
}

function Compare-LightState {
    param([string]$StorageRoot, $State)
    if ($null -eq $State -or $null -eq $State.source_files) { return [ordered]@{ hint = "unknown"; reason = "missing_state"; changed_files = @() } }
    # 中文：只比较元数据，避免路径问题触发解密或导出。
    # English: Compare metadata only; status checks must never decrypt or export.
    $relativePaths = @("contact\contact.db", "contact\contact.db-wal", "message\message_0.db", "message\message_0.db-wal", "message\media_0.db", "message\media_0.db-wal", "message\message_resource.db", "message\message_resource.db-wal")
    $previous = @{}
    foreach ($file in $State.source_files) { $previous[[string]$file.relative_path] = $file }
    $changed = @()
    foreach ($relativePath in $relativePaths) {
        $current = Get-LightFileEntry -StorageRoot $StorageRoot -RelativePath $relativePath
        $old = if ($previous.ContainsKey($relativePath)) { $previous[$relativePath] } else { $null }
        if ($null -eq $old -or [bool]$current.exists -ne [bool]$old.exists) { $changed += $relativePath; continue }
        if ($current.exists -and ([int64]$current.length -ne [int64]$old.length -or [string]$current.last_write_utc -ne [string]$old.last_write_utc)) { $changed += $relativePath }
    }
    if ($changed.Count -eq 0) { return [ordered]@{ hint = "no_obvious_change"; reason = "metadata_matches_last_refresh"; changed_files = @() } }
    return [ordered]@{ hint = "changed_or_missing"; reason = "metadata_differs_from_last_refresh"; changed_files = $changed }
}

$workspace = Resolve-IfExists -Path $WorkspaceRoot
$wechatFiles = Resolve-IfExists -Path $WeChatFilesRoot
$accountRoot = if ($null -ne $wechatFiles) { Resolve-IfExists -Path (Join-Path $wechatFiles $AccountFolder) } else { $null }
$dbStorage = if ($null -ne $accountRoot) { Resolve-IfExists -Path (Join-Path $accountRoot "db_storage") } else { $null }
$outputsRoot = if ($null -ne $workspace) { Join-Path $workspace "outputs" } else { $null }
$statePath = if ($null -ne $outputsRoot) { Join-Path $outputsRoot "wechat_refresh_state.json" } else { $null }
$state = if ($null -ne $statePath) { Read-State -Path $statePath } else { $null }
$latestDecrypted = if ($null -ne $outputsRoot -and (Test-Path -LiteralPath $outputsRoot)) { Get-ChildItem -LiteralPath $outputsRoot -Directory -Filter "decrypted_current_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName } else { $null }
$stateComparison = if ($CompareState -and $null -ne $dbStorage) { Compare-LightState -StorageRoot $dbStorage -State $state } else { [ordered]@{ hint = "not_checked"; reason = "pass_compare_state_for_metadata_check"; changed_files = @() } }

[ordered]@{
    mode = "inspect_only"; did_decrypt = $false; did_export = $false; did_transcribe = $false
    account_root = $accountRoot; live_db_storage = $dbStorage; workspace_root = $workspace
    refresh_state_path = $statePath; refresh_state_exists = ($null -ne $state)
    last_refresh_updated_at = if ($null -ne $state) { [string]$state.updated_at } else { $null }
    last_decrypted_output = if ($null -ne $state) { [string]$state.decrypted_output } else { $null }
    latest_decrypted_directory = $latestDecrypted; refresh_hint = $stateComparison
} | ConvertTo-Json -Depth 8
