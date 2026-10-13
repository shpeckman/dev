# AGENTS.md

Orientation for AI agents working on this repository.

## Layout

- `src/tools/` — one `.cr` file per CLI tool, compiled to a same-named binary.
  Currently a single tool: `dev.cr` → `dev`. The entry point assembles one
  `App` from the command modules below and ends with `exit DevTool.main`.
- `src/dev.cr` + `src/dev/` — the shared `Dev` library, both the support
  modules and the per-feature command modules:
  - `Dev::CLI` — declarative command/option parsing (`App`, `cmd`, `Opt`),
    `die`/`info`/`ok`/`note` messaging
  - `Dev::Theme` — colorized output roles and backtick accent markup
  - `Dev::Graph` — box-drawing/nerd-font commit-graph rendering with
    width-aware subject wrapping
  - `Dev::Terminal` — ioctl terminal width detection
  - `Dev::Git` — shared git/gh plumbing (`invoke` runs both tools; `git`,
    `git_stdout`, `gh` with inherited stdin for its prompts, `require_gh`,
    branch and tag helpers, `resolve`, `ancestor?`, `remote_tags`,
    `gh_repo_exists?`)
  - `Dev::Project` — the git-workflow commands (`init`/`clone`/`open`/`save`/
    `undo`/`release`/`status`/`backup`/`remote`) and their handlers, including
    GitHub repo management (`origin_repo`, `--vis`, `--del`), release
    tagging from the `shard.yml` version (`TagPlan`, the version guard, the
    foreign-tag warning and the status version line)
  - `Dev::Tok`, `Dev::Loc`, `Dev::Chlog` — the analysis commands
- `shard.yml` — shard manifest; the single build `target` (`dev`) lives here
- `makefile` — `make install` builds `src/tools/dev.cr` (release) into
  `~/.local/bin/dev` and copies `SKILL.md` to `~/.agents/skills/dev/`;
  `make uninstall` removes `dev` and any leftover `project`/`tok`/`loc`/`chlog`
- `SKILL.md` — the user-facing skill describing modes, code standards, and
  the git workflow (keep it in sync with `src/dev/project.cr`)

## Build / test

- Build: `shards build dev` (output in `bin/`, gitignored)
- Install: `make install`
- There is no spec suite; verify by running the built binary
  (e.g. `./bin/dev status`, `./bin/dev release --dry-run -m "test"`).
  For release tagging, use a scratch repository with a local bare repository
  as `origin` (`git init --bare`) and `$PROJECT_BACKUP_DIR` pointing at a
  scratch directory, so no GitHub remote or real backup is touched.
  For `dev clone` and `dev remote`, put a stub `gh` script first on `PATH`
  that handles `repo clone` (clone the bare repository), `repo view` (print
  `{"nameWithOwner":…,"visibility":…}` JSON), `repo edit`, and `repo delete`
  (read the typed confirmation from stdin).

## Code standards

- Compiler-friendly, performance-focused, idiomatic, data-driven.
- No comments in code, with one exception: every file starts with a comment
  containing its path (e.g. `# src/tools/dev.cr`).
- Never use `out` as an identifier — it is a reserved keyword.
- The usage-facing API must be ergonomic.
- Never touch the `version` field in `shard.yml`.
- Keep `SKILL.md`, `README.md`, and this file in sync with the code.

## Git workflow

Work happens on `dev` only; `main` is a publish target. Use the repo's own
`dev` tool (`dev init` / `dev clone` / `dev open` / `dev save -m ...` /
`dev status`) for commits; it pushes automatically. `dev init` (and any
command that pushes) creates the GitHub remote via `gh` when `origin` is
missing; default visibility is private (`$PROJECT_PUBLIC=1` makes it public,
`$PROJECT_REMOTE` overrides the `owner/name` slug). Branches are never deleted.
`dev remote --vis` changes the GitHub repo's visibility; `dev remote --del`
deletes the GitHub repo (bundle backup first, `gh` confirmation, `delete_repo`
scope) — run it only at the user's explicit request. `dev release` tags
`v<version>` from `shard.yml` and refuses to reuse a released version with
different content; `dev` never edits `version`. See `SKILL.md` for the full
workflow description.