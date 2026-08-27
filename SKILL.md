---
name: wechat-vibe-export
description: Check freshness and export locally authorized WeChat data without needlessly repeating decryption or export work. Use for local WeChat conversation export, media metadata, or voice-transcription workflows; do not use it to control WeChat or send messages.
---

# WeChat Vibe Export

Use this skill only with data the user is authorized to access. It is a local, read-only workflow: it does not automate the WeChat client, send messages, or modify live databases.

## Choose the lightest operation

- For paths, setup, or last-refresh status, run `scripts/inspect-wechat-workspace.ps1`. It only reads filesystem metadata and the refresh-state file.
- Before reading, exporting, or summarizing conversation content, run `scripts/refresh-latest-wechat.ps1`. It fingerprints the source databases and WAL files, then reuses an intact decrypted snapshot and export if unchanged.
- Before saying that no voice, media, or recent messages exist, refresh the source and inspect the resulting export.

## Refresh command

Call the script from a workspace that contains an `outputs/` directory, supplying environment-specific paths explicitly:

```powershell
& "$SkillRoot/scripts/refresh-latest-wechat.ps1" `
  -WorkspaceRoot "<workspace>" `
  -ToolRoot "<decrypt-tool-project>" `
  -WeChatStorage "<account>/db_storage" `
  -AccountId "<decrypted-account-id>" `
  -TargetLabel "<safe-output-label>" `
  -ExtractScript "<conversation-exporter.py>" `
  -OutputEnvironmentVariable "<exporter-output-env-var>"
```

Use `-ForceRefresh` only when the source signature is known to be stale or the verified snapshot is invalid. Use `-ForceExport` only when the selected export needs rebuilding despite an unchanged source.

The script expects a compatible decrypt-tool project with `.venv\\Scripts\\python.exe` and `vendor/WeChatDataAnalysis-selected/src`. Override either with `-PythonExecutable` or `-DecryptModulePath` when the local layout differs.

## State and privacy boundary

The state file is `outputs/wechat_refresh_state.json`. It may contain only source metadata, signatures, timestamps, and output paths. Do not store chat text, database keys, media bytes, login state, or decrypted databases in it or in a public repository.

For voice messages, cache source audio and transcripts by a stable message identifier and content checksum. Keep raw and cleaned transcripts separate, and identify any uncertain recognition explicitly.

## Windows notes

Use UTF-8 when reading or writing text files. Pass paths containing Chinese characters through script parameters or environment variables rather than shell heredocs.
