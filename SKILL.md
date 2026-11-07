---
name: wechat-vibe-export
description: Refresh and export locally authorized WeChat database snapshots with metadata-only inspection, source-signature reuse, incremental voice handling, and evidence-bounded summaries. Do not use it to control WeChat or send messages.
---

# WeChat Vibe Export

Use this skill only with WeChat data the user is authorized to access. The workflow reads local database metadata and writes local snapshots, state, and export outputs. It does not automate the WeChat client, send messages, or modify live databases.

## Route to the lightest operation

- For paths, setup, or refresh-status questions, run `scripts/inspect-wechat-workspace.ps1`. It must not decrypt, export, transcribe, or read message bodies.
- Before reading, exporting, summarizing, or analyzing conversation content, run `scripts/refresh-latest-wechat.ps1` from the workspace root.
- Before claiming that there are no recent messages, voices, videos, or media, inspect the latest export and compare its time range with the live source metadata.

## Metadata-only inspection

```powershell
& "$SkillRoot/scripts/inspect-wechat-workspace.ps1" `
  -WorkspaceRoot "<workspace>" `
  -WeChatFilesRoot "<wechat-files-root>" `
  -AccountFolder "<account-folder>" `
  -CompareState
```

`-CompareState` compares file existence, size, and modification time only. It does not calculate a content hash or trigger a refresh.

## Freshness gate and export

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

The refresh helper fingerprints these source files when present:

- `contact/contact.db` and its WAL
- `message/message_0.db` and its WAL
- `message/media_0.db` and its WAL
- `message/message_resource.db` and its WAL

It reuses the prior decrypted snapshot only when the source signature matches and all required decrypted databases are present. It reuses a target export only when the source signature, exporter path metadata, and marker file still match. Otherwise it creates a date-stamped decrypted snapshot or export directory and updates `outputs/wechat_refresh_state.json`.

Use `-ForceRefresh` only when the verified snapshot is stale or invalid. Use `-ForceExport` only when the selected export must be rebuilt even though the source is unchanged. If a matching signature still produces an export whose latest message is too old for the request, compare the live database/WAL metadata and run one forced refresh and export.

The helper accepts optional `-KeyPath`, `-PythonExecutable`, and `-DecryptModulePath` parameters when the local decrypt project does not use its default layout. The key is read locally and is never written to the refresh state.

Use a safe `TargetLabel` containing letters, digits, `_`, or `-` only. Treat `OutputEnvironmentVariable` as a variable name, not a path; do not pass user text that contains path separators or shell syntax.

## Exporter contract

The target-specific exporter is supplied by the user and must:

1. Read `WECHAT_DECRYPTED_BASE` to locate the verified decrypted databases.
2. Read the output directory from the environment variable named by `-OutputEnvironmentVariable`.
3. Write `<TargetLabel>_messages.json` as its completion marker.
4. Keep raw message fields and resource references available for later verification.

The exporter may also write Markdown, TXT, HTML, manifests, and resource indexes. Do not treat an exporter result as complete until its message count and time range are checked against the source query.

## Media and voice handling

- Read the latest JSON export and relevant XML or `appmsg` payloads for media links. Do not infer media contents from stale Markdown or a filename alone.
- Cache voice work by a stable message identifier and a checksum of the original bytes. Reuse matching raw audio, WAV, and transcript artifacts; decode and transcribe only new or changed audio.
- WeChat SILK data may begin with `0x02#!SILK_V3`. Preserve the leading byte when passing the original blob to the decoder; a stripped `.silk` file is only an auxiliary artifact.
- Keep raw and cleaned transcripts separate. Mark uncertain recognition explicitly instead of silently correcting names, dates, or commitments.
- When the local Vibe executable or model is unavailable, report voice processing as incomplete. Do not claim that the conversation was fully processed.

## Evidence-bounded summaries

When producing a summary, separate:

- facts directly present in the exported messages;
- inferences supported by multiple messages;
- unresolved, planned, promised, or recognition-uncertain items.

Do not turn a proposal, promise, forwarded claim, or missing record into a completed fact. Keep contacts, groups, dates, and media scopes separate unless the user explicitly authorizes combining them.

## Privacy and public-repository boundary

The public repository contains only generic workflow code and documentation. Never commit:

- `outputs/`, decrypted databases, chat exports, raw media, voice data, or transcripts;
- database keys, tokens, login state, account identifiers, or machine-specific credentials;
- private exporter results or copied local configuration files.

`outputs/wechat_refresh_state.json` may contain only source metadata, signatures, timestamps, and output paths. It is ignored by default, but an accidentally committed state file can reveal local usernames and directory structure. Review `git status`, `git diff --cached`, `git ls-files`, and recent history before every public push.

## Localized path handling

On Windows, pass paths containing non-ASCII characters through parameters or environment variables. Use UTF-8 for text files and do not interpret terminal mojibake as evidence that a file is corrupted.
