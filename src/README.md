# src/

Modular source for scripts that get assembled into self-contained "fat" scripts by CI before they're served to RMM endpoints.

## Why this exists

NinjaRMM (and every other RMM we deploy through) downloads exactly one PowerShell file when a script runs. Endpoints don't dot-source from the internet at runtime ... that adds a fetch-and-verify dance, hash placeholders, and a failure mode that's invisible until a customer endpoint silently breaks.

So we author small, focused, reusable source files here under `src/`, and a CI job inlines them into one fat script per leaf at build time. The fat scripts get committed to the `published` branch and served via jsDelivr.

```
src/                          (you author here)
  oem-shared/lib/oem-manufacturer-detect.ps1
  oem-dell/dell-configure.ps1
  oem-dell/lib/dell-detection.ps1
       |
       |  GHA workflow: push to development or main
       v
published/                    (CI writes here, on a separate branch)
  oem-dell/dell-configure.ps1     <-- fat, self-contained, served via jsDelivr
```

The `published` branch is never authored by hand. Treat it as read-only build output.

## `# %INCLUDE` marker syntax

A leaf script pulls in shared lib code by adding a comment marker on its own line:

```powershell
# %INCLUDE oem-shared/lib/oem-manufacturer-detect.ps1
# %INCLUDE oem-dell/lib/dell-detection.ps1
```

Rules:

- The path is **relative to the repo root** (not relative to `src/`). Example: `# %INCLUDE oem-shared/lib/oem-manufacturer-detect.ps1` resolves to `<repo-root>/oem-shared/lib/oem-manufacturer-detect.ps1` ... but in practice all lib sources live under `src/`, so the include path will start with `src/` for in-source libs (e.g. `# %INCLUDE src/oem-shared/lib/oem-manufacturer-detect.ps1`).
- The match is strict: the line must begin with optional whitespace, then `#`, then optional whitespace, then `%INCLUDE`, then whitespace, then the path. Anything else is left alone.
- The marker line is replaced at build time by the included file's content, framed with `# === inlined from <path> ===` / `# === end inline ===` so the fat output is greppable when something breaks.
- **Recursive includes are not supported in V1.** Lib files cannot themselves contain `# %INCLUDE` markers. The build will fail loudly if it sees one. If you want a lib to depend on another lib, the leaf should `# %INCLUDE` both, in dependency order.
- Each include is inlined per occurrence. Two leaves that both `# %INCLUDE` the same lib each get their own inlined copy ... that's the point of fat scripts.

## How the build runs

The workflow at `.github/workflows/build-fat-scripts.yml` triggers on push to `development` and `main`:

1. Walks `src/` recursively, finds every `.ps1`.
2. Calls `.github/scripts/build-fat-scripts.ps1` to expand the `# %INCLUDE` markers.
3. Writes the fat output to the matching relative path on the `published` branch, with the leading `src/` stripped (so `src/oem-dell/dell-configure.ps1` becomes `oem-dell/dell-configure.ps1` in the published tree).
4. Commits with a message that names the source short SHA and subject (`build: from <source-sha-short> "<source commit subject>"`).
5. On push to `main`, moves the `release` tag to the new published commit; on push to `development`, moves the `dev` tag.

`release` is the production-pinned tag NinjaRMM URLs reference; `dev` is for staging script presets.

## Layout convention

Same `category-vendor` / `category-app` folder convention as the rest of the repo, just nested under `src/`:

```
src/oem-shared/lib/
src/oem-dell/
src/oem-dell/lib/
src/oem-hp/
src/oem-hp/lib/
```

Lib files conventionally live in a `lib/` subfolder. Leaf scripts (the ones RMM actually invokes) live one level up. Same kebab-case file naming as the rest of the repo.

## Source vs Published, at a glance

| Concern | `src/` (this directory) | `published/` (branch, CI output) |
|---|---|---|
| Edited by | Humans, via PR | CI, never by hand |
| Contains | Small modular source files with `# %INCLUDE` markers | Self-contained fat scripts |
| Branch | `development` and `main` | `published` (separate orphan branch) |
| URL | Not served to RMM directly | `https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@release/<path>` |

Production NinjaRMM script presets reference `@release` (a tag on `published`); staging or dev presets can reference `@dev`. Immutable per-version pins (`@<commit-sha>`) are also valid and recommended for anything customer-facing where you want to lock the exact build.
