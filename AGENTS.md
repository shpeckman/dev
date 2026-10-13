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
  - `Dev::LLM` — DeepSeek chat-completions client (`complete`, JSON output
    mode, thinking disabled; `available?` = `$DEEPSEEK_API_KEY` set and
    stdin/stdout are TTYs; `$PROJECT_LLM_MODEL`, default `deepseek-flash`);
    failures raise `LLM::Failure`
  - `Dev::Proposal` — `dev save` only: builds the staged-diff `Context`
    (`staged`), asks for a `Draft` (message, `Bump`, reason; the bump is
    forced to `none` unless `bumpable`), computes versions with stdlib
    `SemanticVersion`, and runs the y/e/n confirmation
  - `Dev::Project` — the git-workflow commands (`init`/`clone`/`open`/`save`/
    `undo`/`release`/`status`/`backup`/`remote`) and their handlers, including
    `undo --to` (`restore_source` validates, `restore_to` commits the restore),
    GitHub repo management (`origin_repo`, `--vis`, `--del`), release
    tagging from the `shard.yml` version (`TagPlan`, the version guard, the
    foreign-tag warning and the status version line), and the `save`
    proposal hook (`propose_save_message`; a bump is allowed when
    `tag_commits` finds `v<version>`, and `write_version` rewrites the
    `version:` line). `release` never uses DeepSeek.
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
  (e.g. `./bin/dev status`, `./bin/dev release --dry-run -m "test"`,
  `./bin/dev undo --to HEAD~2` in a scratch repository).
  For release tagging, use a scratch repository with a local bare repository
  as `origin` (`git init --bare`) and `$PROJECT_BACKUP_DIR` pointing at a
  scratch directory, so no GitHub remote or real backup is touched.
  For `dev clone` and `dev remote`, put a stub `gh` script first on `PATH`
  that handles `repo clone` (clone the bare repository), `repo view` (print
  `{"nameWithOwner":…,"visibility":…}` JSON), `repo edit`, and `repo delete`
  (read the typed confirmation from stdin).
  For DeepSeek proposals, build a scratch copy with `Dev::LLM::ENDPOINT`
  pointed at a local stub server that returns
  `{"choices":[{"message":{"content":"{\"message\":…,\"bump\":…,\"reason\":…}"},"finish_reason":"stop"}]}`,
  and run `dev save` under a pseudo-terminal (proposals only run
  when stdin and stdout are TTYs). Never test against the real API.

## Code standards

- Compiler-friendly, performance-focused, idiomatic, data-driven.
- No comments in code, with one exception: every file starts with a comment
  containing its path (e.g. `# src/tools/dev.cr`).
- Never use `out` as an identifier — it is a reserved keyword.
- The usage-facing API must be ergonomic.
- Never touch the `version` field in `shard.yml`.
- Prevent "shotgun surgery".
- Keep `SKILL.md`, `README.md`, and this file in sync with the code.

## Git workflow

Work happens on `dev` only; `main` is a publish target. Use the repo's own
`dev` tool (`dev init` / `dev clone` / `dev open` / `dev save -m ...` /
`dev status`) for commits; it pushes automatically. Agents always pass `-m`:
DeepSeek proposals run only in a real terminal. To return `dev` to an
earlier state, use `dev undo --to REV` (a new commit, history kept). `dev init` (and any
command that pushes) creates the GitHub remote via `gh` when `origin` is
missing; default visibility is private (`$PROJECT_PUBLIC=1` makes it public,
`$PROJECT_REMOTE` overrides the `owner/name` slug). Branches are never deleted.
`dev remote --vis` changes the GitHub repo's visibility; `dev remote --del`
deletes the GitHub repo (bundle backup first, `gh` confirmation, `delete_repo`
scope) — run it only at the user's explicit request. `dev release` tags
`v<version>` from `shard.yml` and refuses to reuse a released version with
different content; `dev` edits `version` only when the user accepts a
DeepSeek proposal during `dev save` in a terminal. See `SKILL.md` for the full workflow
description.