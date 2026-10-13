# dev

A Crystal shard providing a single `dev` CLI tool plus the shared `Dev`
support library (`Dev::CLI`, `Dev::Theme`, `Dev::Graph`, `Dev::Terminal`,
`Dev::Git`) it is built on.

## Tool

`dev` is one command with flat subcommands: a two-branch git workflow
(`init`/`clone`/`open`/`save`/`undo`/`release`/`status`/`backup`/`remote`) plus three analysis
subcommands (`tok`/`loc`/`chlog`).

### Git workflow

The model: all work happens on `dev`; `main` is a publish target of clean
squash-merged releases and is never worked on directly. Feature branches do not
exist. Branches are never deleted, nothing is force-pushed (except one guarded
amend of `main`'s tip), and mutating operations refuse to run on a dirty tree —
except `undo --hard`, which discards the uncommitted changes. The GitHub repo
itself is only deleted by an explicit `remote --del`, after a backup bundle.

```
dev init                                 initialize a git repository here (on main) and create its remote;
                                         refuses when backup bundles or the GitHub repo already exist
dev clone <owner/name | url> [<dir>]     clone a GitHub repo, then land on dev (runs dev open)
dev open                                 sync main, checkout or create dev, fast-forward and push
                                         (creates the remote if missing)
dev save -m MSG [--no-add] [--no-push]   commit all changes on dev and push
dev undo [--hard]                        revert the last commit or merge on dev and push;
                                         --hard discards uncommitted changes first
dev release [-m MSG] [options]           bundle backup, squash-merge dev into main, tag the shard.yml
                                         version, reconcile and push (creates the remote if missing)
dev release --no-tag                     release without tagging or the version guard
dev release --cancel                     back out of a conflicted release, return to dev
dev release --edit-title -m MSG          amend main's tip title (backup, tags moved, force-with-lease)
dev status [-n LIMIT]                    show branch, dirty files, shard version, unpushed counts,
                                         last backup, and the commit graph
dev backup                               write a backup bundle of all refs
dev backup --list                        list backup bundles
dev backup --restore [NAME]              restore a bundle's branches and tags as restore/<stamp>/<name>
dev remote                               show origin's GitHub slug, URL and visibility
dev remote --vis public|private          change the visibility of origin's GitHub repo
dev remote --del                         backup bundle, then delete origin's GitHub repo
```

#### Remote repo

`dev clone` and `dev remote` require the GitHub CLI (`gh`), installed and
authenticated.

- `dev clone` clones via `gh repo clone` into `<dir>` (default: the repository
  name) and runs `dev open` inside it; `dev` is checked out from `origin/dev`
  when it exists. Refuses inside a git repository or when `<dir>` exists.
- `dev remote` resolves the GitHub repo from `origin`'s URL, not the directory
  name.
- `--vis` is a no-op when the visibility is already set, and prints the
  consequences of a change (lost stars and watchers, detached public forks,
  disabled push rulesets, exposed GitHub Actions history and logs).
- `--del` fetches `origin` with tags, writes a backup bundle, warns about tags
  published on `origin` (shards consumers lose those releases), then lets `gh`
  prompt for the repo name as confirmation. It needs the `delete_repo` token
  scope (`gh auth refresh -h github.com -s delete_repo`). Local history and the
  `origin` remote are kept; `git remote remove origin` lets the next push
  create a new GitHub repo.

#### Release tags

When `shard.yml` on `dev` has a `version`, `dev release` creates an annotated
tag `v<version>` on the new `main` commit (message: the release title) and
pushes only that tag. Shards resolves dependency versions from these tags.

- Version guard: if `v<version>` already exists locally or on `origin` with
  different content, the release is refused before anything changes — bump
  `version` in `shard.yml` first (`dev` never edits it), or pass `--no-tag`.
  A tag with identical content is left as is.
- Foreign tags: `dev open` and `dev release` warn about tags on `origin` that
  are not reachable from `main` or `dev` (the mark of a recreated history).
  Shards never prunes deleted tags from its cache, so after such tags are
  removed, consumers must delete their cached copy under `~/.cache/shards/`.
- `dev status` shows the version state: not yet released, released, released
  but changed since (bump before the next release), not pushed, outside this
  history, or origin unreachable.
- `dev release --edit-title` moves tags on `main`'s tip and keeps annotated
  tags annotated, with the new title as message.

Environment overrides: `$PROJECT_MAIN` (default: detected `main`/`master`),
`$PROJECT_DEV` (default: `dev`), `$PROJECT_REMOTE` (default: directory name;
use `owner/name` to override), `$PROJECT_PUBLIC=1` (make auto-created remotes
public instead of private), `$PROJECT_BACKUP_DIR` (default
`~/.local/share/project/backups/<repo>/`, falling back to the old
`~/.local/share/gitflow/backups/<repo>/` when it exists), `$PROJECT_WIDTH`
(help/graph wrap width; `0` disables), `$PROJECT_TREE=branch|box` (force graph
glyph style).

### tok

Estimates token counts for source code and text files, rendered as a
directory tree.

```
dev tok [<targets>...]
```

### loc

Counts lines of code grouped by language, with a per-language breakdown of
files, total / blank / comment / code lines, plus a grand total. Skips binary
and hidden files; unrecognized text files are grouped as `other`.

```
dev loc [<targets>...]
```

### chlog

Generates a changelog from the release history on `main` — one entry per
release commit, newest first.

```
dev chlog [<branch>] [-n LIMIT]
```

## Build and install

```
shards build dev     # builds bin/dev
make install         # builds src/tools/dev.cr into ~/.local/bin/dev (release)
                     # and copies SKILL.md to ~/.agents/skills/dev/
make uninstall       # removes dev and any leftover project/tok/loc/chlog binaries
```

Requires Crystal >= 1.21.