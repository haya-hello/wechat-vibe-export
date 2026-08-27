# WeChat Vibe Export

A Codex skill for safely refreshing and exporting locally authorized WeChat data. It avoids unnecessary decryption and export runs by fingerprinting the databases and WAL files first.

## What it does

- Provides a metadata-only inspection command for setup and status questions.
- Reuses a verified decrypted snapshot and per-target export when source signatures match.
- Rebuilds only when the source, exporter script, or output validation requires it.
- Leaves WeChat itself untouched: no UI automation, messages, replies, or database writes.

## What it does not include

This repository contains no chat records, decryption keys, account IDs, media files, login state, database files, or machine-specific paths. Keep all of those outside Git.

## Install as a Codex skill

```powershell
git clone https://github.com/haya-hello/wechat-vibe-export.git "$env:USERPROFILE\.codex\skills\wechat-vibe-export"
```

Restart Codex or refresh its skill list after installing.

## Local requirements

The refresh helper is an adapter for a local WeChat decryption project. Supply its paths as parameters; it expects a Python environment and a compatible `wechat_decrypt_tool` module. You also need a target-specific exporter that reads `WECHAT_DECRYPTED_BASE` and writes `<TargetLabel>_messages.json` to the directory named by your output environment variable.

See [SKILL.md](SKILL.md) for the workflow and required parameters.

## Privacy

Use only data you are authorized to access. Do not commit the `outputs/` directory, keys, decrypted databases, raw media, or exporter results. The repository's `.gitignore` blocks common sensitive artifacts, but you remain responsible for reviewing staged changes before every push.

## License

No license has been selected yet. The repository is published for inspection and collaboration; reuse rights are not granted by default.
