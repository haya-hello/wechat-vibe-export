# WeChat Vibe Export

A public Codex Skill for refreshing and exporting locally authorized WeChat data without repeating expensive decryption or export work. It fingerprints the source databases and WAL files, reuses verified outputs when they are still valid, and keeps voice processing incremental.

## Scope

This project is a local workflow adapter. It does not log in to WeChat, automate the WeChat client, send or reply to messages, modify live databases, or provide a network crawler. You must supply the local decrypt project and a target-specific exporter.

The refresh helper does write local state, decrypted snapshots, and export outputs under the workspace `outputs/` directory. “Read-only” here means it does not write to the live WeChat databases or control the client.

## Install as a Codex Skill

```powershell
git clone https://github.com/haya-hello/wechat-vibe-export.git `
  "$env:USERPROFILE\.codex\skills\wechat-vibe-export"
```

Restart Codex or refresh its skill list after installing.

## Quick start

Use the metadata-only check for setup or status questions:

```powershell
& "$env:USERPROFILE\.codex\skills\wechat-vibe-export\scripts\inspect-wechat-workspace.ps1" `
  -WorkspaceRoot "<workspace>" `
  -WeChatFilesRoot "<wechat-files-root>" `
  -AccountFolder "<account-folder>" `
  -CompareState
```

Before reading or summarizing messages, run the freshness gate and provide the local paths explicitly:

```powershell
& "$env:USERPROFILE\.codex\skills\wechat-vibe-export\scripts\refresh-latest-wechat.ps1" `
  -WorkspaceRoot "<workspace>" `
  -ToolRoot "<decrypt-tool-project>" `
  -WeChatStorage "<account>/db_storage" `
  -AccountId "<decrypted-account-id>" `
  -TargetLabel "<safe-output-label>" `
  -ExtractScript "<conversation-exporter.py>" `
  -OutputEnvironmentVariable "<exporter-output-env-var>"
```

Use only safe output labels made of letters, digits, `_`, or `-`. `OutputEnvironmentVariable` is an environment-variable name, not a path.

The exporter must read `WECHAT_DECRYPTED_BASE`, write its results to the requested output directory, and create `<TargetLabel>_messages.json` when the export is complete. See [SKILL.md](SKILL.md) for the full contract, freshness rules, media handling, voice cache rules, and evidence boundaries.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- A compatible local decrypt project and Python environment.
- A user-supplied exporter for the requested contact, group, or date range.
- Authorization to access the local WeChat data.

The refresh script accepts `-KeyPath`, `-PythonExecutable`, and `-DecryptModulePath` when the decrypt project uses a different layout. The default paths are only conventions; do not copy private machine paths into this repository.

## Reuse behavior

The refresh state is stored locally at `outputs/wechat_refresh_state.json`. It records source metadata, signatures, timestamps, and output paths only. When the source signature and output validation match, the script reports `decrypt_action=reused` and/or `export_action=reused`. Use `-ForceRefresh` or `-ForceExport` only for a specific stale or invalid result.

Voice processing belongs to the target exporter or a companion local script. Cache by stable message identifier and original-byte checksum, preserve the original WeChat SILK form when decoding, and keep raw and cleaned transcripts separate.

## Public-repository safety

This repository intentionally contains no chat records, database keys, account data, media, transcripts, login state, decrypted databases, or exporter outputs. Keep those files outside Git. The ignored `outputs/` directory and state file can still be force-added accidentally, so before every push review:

```powershell
git status --short
git diff --cached --name-status
git ls-files
git log --all --stat
```

The repository is public for inspection and collaboration. Public visibility does not itself grant reuse rights; no open-source license has been selected yet. Add one only if you want to grant explicit reuse rights.
