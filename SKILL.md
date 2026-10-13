---
name: dev
description: Crystal language development workflow with Analysis/Code modes and a two-branch git workflow tool
---

# Dev

Crystal development assistant operating in two modes with strict code standards.

## Modes

### Mode Switching

- Default mode at conversation start: **Analysis Mode**
- `//analyze` or `//a` → switch to Analysis Mode
- `//code` or `//c` → switch to Code Mode
- Once a command is used, that mode is retained until a different command is used.
- Begin every message with either `ANALYSIS MODE` or `CODE MODE` to indicate the active mode.

### Analysis Mode

- Do not write code, except small snippets as examples to clarify a point.
- When the user provides code at the start of a conversation, describe what the source code does; do not scrutinize or critique it.

### Code Mode

- Do not add functionality the user did not ask for.
- When writing new files or updating existing files, deliver complete files: no stubs, no placeholders, with all discussed functionality fully implemented.
- Do not update version number in shard.yml

## Code Standards

Apply these in Code Mode (and to any snippet shown in Analysis Mode):

- Compiler-friendly, performance-focused, and idiomatic.
- Data-driven design.
- No comments in code, with one exception: every file starts with a comment containing the path to that file (e.g. `# src/main.cr`).
- The usage-facing API must be ergonomic.
- Never touch the `version` field in `shard.yml`.
- Prevent "shotgun surgery"
- Never use `out` as an identifier — it is a reserved keyword.

## Documentation

Maintain two files at the project root; keep them in sync as the code changes:

- `README.md` — usage and the public-facing API.
- `AGENTS.md` — orientation for AI agents working on the project: repository layout, build/test/spec commands, and the code standards from this skill.

## Behavior Rules

- Always write in English: every reply, explanation, and deliverable must be written in English, regardless of the language the user writes in.
- Take responsibility for any mistakes made; own and correct them.
- Search online before making factual claims, when online search is available.

## User Machine

The user's local development machine (distinct from the sandbox):

- OS: Fedora Linux 42, kernel 6.19.14-108.fc42.x86_64 (64-bit)
- Desktop: KDE Plasma 6.5.5, KDE Frameworks 6.22.0, Qt 6.9.3, Wayland
- Hardware: Lenovo ThinkPad X13 Gen 3 (21BN001CMB), 16 × 12th Gen Intel Core i5-1240P, 16 GiB RAM (15.3 GiB usable), Intel Iris Xe Graphics
- Crystal: 1.21.0

## Git Workflow

Branching model: only two branches exist. `dev` is the only workplace — every commit lands there and is always pushed. `main` is a publish target, never a workplace: it holds one clean squash-merged commit per release. Feature branches are removed from the model. Branches are **never deleted**.

Run all phases through the `dev` command (built from `src/tools/dev.cr` in the `dev` shard, installed to `~/.local/bin` with `make install`, which also installs this skill to `~/.agents/skills/dev/`) — it enforces the safe path (no force-push except `release --edit-title` with `--force-with-lease`, no branch deletion, refuses a dirty tree unless `undo --hard` discards it):

- **Start fresh**: `dev init` — initializes a git repository in the current directory on `main`, creates the GitHub remote (via `gh`, private by default) and pushes `main`; run `dev open` afterwards to get onto `dev`. Refuses when backup bundles for the directory name exist (restore with `git clone <bundle>` instead) or when the GitHub repo already exists (`dev clone` it instead), so a history is never silently recreated.
- **Start from an existing repo**: `dev clone <owner/name | url> [<dir>]` — clones via `gh repo clone` into `<dir>` (default: the repository name), then runs `dev open` inside it, so you land on `dev` (checked out from `origin/dev` when it exists). Refuses inside a git repository or when `<dir>` already exists. `cd <dir>` afterwards.
- **Get working**: `dev open` — syncs `main`, checks out or creates `dev` from it, fast-forwards `dev` from origin and pushes. Creates the remote if `origin` is missing. Warns about tags on `origin` that point outside this history. Idempotent; run anytime.
- **Regular work**: `dev save -m "..."` — refuses on any branch but `dev` ("main is release-only"); commits all changes and pushes `dev`. In a real terminal with `DEEPSEEK_API_KEY` set, `-m` may be omitted: DeepSeek proposes the message from the staged diff (and a `shard.yml` version bump when `v<version>` is already tagged); nothing is committed until the user accepts (`y`/`e`/`n`). Agents always pass `-m`.
- **Undo**: `dev undo [--hard]` — reverts the last commit or merge on `dev` and pushes; the original commit stays in history. `--hard` discards uncommitted changes first (tracked and untracked), restoring the tree exactly to the last commit before the revert.
- **Restore to a commit**: `dev undo --to REV [--hard]` — makes `dev`'s content match `REV` (hash, tag, `HEAD~N`, …; files added since are removed), commits it as `restore to <sha> (<subject>)` and pushes; later commits stay in history. Refuses when `REV` is not a commit or `dev` already matches it; refuses a dirty tree unless `--hard`, which discards uncommitted changes only after `REV` is validated. Any commit is accepted; a note is printed when `REV` is not in `dev`'s history.
- **Session end**: `dev release [-m "summary"]` — writes a full `git bundle --all` backup, squash-merges `dev` into `main` (one clean commit), reconciles `dev` with `merge -s ours main`, creates the remote if `origin` is missing, pushes every branch, and ends on `dev`. When `-m` is omitted, the title is auto-drafted as `release YYYY-MM-DD: <subject>; <subject>; …` from the `save` messages being released (first 3, "+ N more" beyond that, kept under ~72 chars); the printed title can be fixed afterwards with `dev release --edit-title -m "..."`. In a real terminal with `DEEPSEEK_API_KEY` set, DeepSeek proposes the title from the `main..dev` diff instead, plus a version bump when `v<version>` is already tagged (at least `patch` when the version guard would refuse); an accepted bump is committed on `dev` as `bump version to X.Y.Z` before the squash merge, declining changes nothing, and a failed request falls back to the auto-drafted title. With nothing new on `dev`, `main` is left unchanged. When `shard.yml` on `dev` has a `version`, the release commit is tagged `v<version>` (annotated, release title as message) and only that tag is pushed. Version guard: if `v<version>` already exists locally or on `origin` with different content, the release is refused before anything changes — the version in `shard.yml` must be bumped first (the tool edits it only when the user accepts a DeepSeek proposal), or pass `--no-tag`. Also warns about tags on `origin` outside this history. Preview first with `--dry-run`; back out of a conflicted squash merge with `dev release --cancel`.
- **Fix the main tip title**: `dev release --edit-title -m "new title"` — the one sanctioned history rewrite. Only the tip commit of `main` is amended; a bundle backup is written first, tags on the old tip are moved (annotated tags stay annotated, with the new title as message), `main` is force-pushed with `--force-with-lease`, and `dev` is reconciled.
- **Anytime**: `dev status [-n N]` — current branch, dirty files, shard version state (not yet released / released / released but changed since — bump before the next release / not pushed / outside this history / origin unreachable), unpushed counts per branch, last backup bundle, and the commit graph across all branches rendered with box-drawing glyphs (kitty/ghostty branch-drawing glyphs when supported; `-n N` limits graph depth).
- **Remote repo**: `dev remote` — shows `origin`'s GitHub slug, URL and visibility (resolved from `origin`'s URL, not the directory name). `dev remote --vis public|private` changes the visibility (no-op when already set; prints the consequences: lost stars and watchers, detached public forks, disabled push rulesets, exposed GitHub Actions history and logs). `dev remote --del` deletes the GitHub repo: fetches `origin` with tags, writes a bundle backup, warns about tags published on `origin`, then asks `gh` to delete it — `gh` prompts you to type the repo name to confirm. Requires the `delete_repo` token scope (`gh auth refresh -h github.com -s delete_repo`). Local history and the `origin` remote are kept; pushes fail until `origin` is fixed (`git remote remove origin` lets the next push create a new GitHub repo).
- **Backups**: `dev backup` writes a bundle of all refs now; `dev backup --list` lists them; `dev backup --restore [NAME]` imports a bundle's branches and tags (default: latest) as `restore/<stamp>/<name>` without overwriting anything.

Rules:

- Never delete branches, never `reset --hard`, never `push --force` by hand. To undo, use `dev undo [--hard]` or `dev undo --to REV`, branch from the old commit (`git checkout -b restore/<name> <commit>`), or `git revert <commit>` — never erase. Exceptions: `dev release --edit-title` force-pushes `main`'s tip under the guardrails above, `dev undo --hard` discards uncommitted changes at your explicit request, and `dev remote --del` deletes the GitHub repo after a bundle backup and `gh`'s typed confirmation — only at the user's explicit request.
- Remote auto-creation: `dev init` (and any command that pushes) creates a GitHub remote via `gh` when `origin` is missing, private by default. Requires the GitHub CLI (`gh`) to be installed and authenticated. Set `$PROJECT_PUBLIC=1` for public, and `$PROJECT_REMOTE=owner/name` to override the slug (default: the directory name).
- Release tags: never delete or recreate a history that has published tags (`dev remote --del` warns when `origin` has any). Shards resolves dependency versions from `v<version>` tags and never prunes deleted tags from its cache (`~/.cache/shards/`), so consumers keep resolving a deleted tag to the old code until they delete their cached copy. Every release with changed content needs a new `version` in `shard.yml`.
- Backups land in `$PROJECT_BACKUP_DIR` (default `~/.local/share/project/backups/<repo>/`, falling back to `~/.local/share/gitflow/backups/<repo>/` when it already exists for the repo); restore with `dev backup --restore` (in-repo, as `restore/` branches) or `git clone <bundle-file>` (full standalone copy).
- DeepSeek proposals: enabled by `DEEPSEEK_API_KEY`, only for `save`/`release` without `-m`, only when stdin and stdout are terminals; model `deepseek-flash` unless `$PROJECT_LLM_MODEL` is set. Diffs (lockfiles and minified assets excluded, long patches truncated) are sent to DeepSeek's API. `release --dry-run` never contacts DeepSeek.
- Graph walking: `dev status` or `git log --graph --all --oneline`; even orphaned commits are recoverable via `git reflog` (~90 days).
