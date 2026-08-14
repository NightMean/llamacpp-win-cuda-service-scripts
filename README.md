# llamacpp-win-cuda-service-scripts

English | [中文](README.zh-CN.md)

PowerShell scripts for downloading, updating, switching, and running a local
Windows CUDA build of [llama.cpp](https://github.com/ggml-org/llama.cpp) as a
`llama-server` instance.

This repository is intentionally script-only. It does not include downloaded
llama.cpp binaries, CUDA runtime files, model files, logs, runtime state, or
private tokens.

## What It Does

- Checks the latest `ggml-org/llama.cpp` release on GitHub.
- Selects the newest matching Windows x64 CUDA release asset pair.
- Downloads and verifies release archives when GitHub provides SHA-256 digests.
- Installs the selected build into a versioned local directory.
- Switches `llama-current` to the active install directory.
- Starts, stops, and checks a local `llama-server`.
- Keeps a small number of previous installs and cached archives for rollback.

## Requirements

- Windows PowerShell.
- Windows with an NVIDIA GPU and a compatible driver for the selected CUDA
  build.
- Network access to GitHub releases.
- Local GGUF model files.
- Optional: GitHub CLI or a `GITHUB_TOKEN`/`GH_TOKEN` environment variable to
  avoid unauthenticated GitHub API rate limits.

## Quick Start

1. Clone this repository.
2. Copy `llama-config/models.example.ini` to `llama-config/models.ini`.
3. Edit `llama-config/models.ini` and point `model = ...` entries to your local
   GGUF files.
4. Optional: set `GITHUB_TOKEN` or `GH_TOKEN` in your environment. If you prefer
   a local file, copy `llama-config/github-token.example.txt` to
   `llama-config/github-token.txt` and put the token there.
5. Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\llama-scripts\update-llamacpp-cuda13.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\llama-scripts\start-llamacpp-server.ps1
```

The default server URL is `http://127.0.0.1:8080`.
The bind address and port are read from the `[*]` section of
`llama-config/models.ini`, so moving to another machine or port does not require
editing the start, stop, or update scripts.

To start the server automatically when Windows starts, even before the user
logs on, run this command in an elevated PowerShell window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\llama-scripts\register-start-task-at-startup.ps1
```

If the `Start llama.cpp server` task does not exist, this command creates it.
It only replaces a task when one with the same name already exists. The task
runs 30 seconds after system startup by default; use `-DelaySeconds` to change
the delay. The repository may be installed in any directory because the script
resolves the project path from its own location.

The task uses S4U so it can run without storing the account password. Windows
does not give S4U tasks access to network shares or EFS-encrypted files, so keep
the repository, configuration, and GGUF models on locally accessible paths.

## Scripts

- `llama-scripts/update-llamacpp-cuda13.ps1`: downloads, installs, switches,
  restarts, and cleans up old local builds.
- `llama-scripts/start-llamacpp-server.ps1`: starts `llama-server` with the local
  models preset.
- `llama-scripts/stop-llamacpp-server.ps1`: unloads loaded models and stops the
  server process.
- `llama-scripts/restart-llamacpp-server.ps1`: stops and then starts the server
  so `llama-config/models.ini` changes are loaded.
- `llama-scripts/check-llamacpp-version.ps1`: compares the local active build
  with the latest upstream release.
- `llama-scripts/register-start-task-at-startup.ps1`: registers a Windows
  startup task that does not require an interactive logon; it creates the task
  on a new machine and replaces an old task only when the same name exists.
- `llama-scripts/register-update-task-run-logged-off.ps1`: registers a Windows
  scheduled task for periodic updates; it creates the task on a new machine and
  replaces an old task only when the same name exists.
- `llama-scripts/test-llama-scripts.ps1`: runs lightweight script tests.

## Configuration

The private configuration file is `llama-config/models.ini`. It is ignored by
Git because it usually contains machine-specific model paths.

The private token file is `llama-config/github-token.txt`. It is also ignored by
Git. Prefer environment variables when possible:

```powershell
$env:GITHUB_TOKEN = "your_token_here"
```

## Repository Hygiene

The `.gitignore` excludes:

- `llama-config/github-token.txt`
- `llama-config/models.ini`
- downloaded llama.cpp/CUDA binaries
- download cache archives
- logs and runtime pid files
- the `llama-current` junction

Do not commit model files, CUDA DLLs, release ZIP files, logs, or local tokens.

## License

The scripts in this repository are released under the MIT License. Downloaded
llama.cpp artifacts remain under their upstream licenses, and CUDA runtime
components are governed by NVIDIA's license terms.
