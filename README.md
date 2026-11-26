# bash-backup-rotate — timestamped tar backups with rotation (Bash)

A single Bash script (bash 4+, coreutils/tar only) that creates timestamped .tar.zst (or .tar.gz fallback if zstd is absent) archives of given source paths into a backup directory, keeps the newest N archives per source (rotation with a printed deletion list and a --dry-run mode), writes a SHA-256 sidecar for each archive, and logs every action. Usage flags: --sources, --dest, --keep, --dry-run. Refuses to run if the destination is inside a source path. The deliverable is the complete .sh file.

Produced by the Azure Foundry bench (draft gpt-6.2-astra-1, perfected by Kimi-K2.7-Code, QC by DeepSeek-V4-Pro) under Dr. Brent Allen Jensen's production order of Nov 25, 2026. Local gates: files: bash-backup-rotate.sh 8046 B.
