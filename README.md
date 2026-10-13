# dev

A Crystal shard providing a single `dev` CLI tool plus the shared `Dev`
support library (`Dev::CLI`, `Dev::Theme`, `Dev::Graph`, `Dev::Terminal`,
`Dev::Git`) it is built on.

## Tool

`dev` is one command with flat subcommands: a two-branch git workflow
(`init`/`open`/`save`/`undo`/`release`/`status`/`backup`) plus three analysis
subcommands (`tok`/`loc`/`chlog`).

### Git workflow

The model: all work happens on `dev`; `main` is a publish target of clean
squash-merged releases and is never worked on directly. Feature branches do not
exist. Branches are never deleted, nothing is force-pushed (except one guarded
amend of `main`'s tip), and mutating operations refuse to run on a dirty tree —
except `undo --hard`, which discards the uncommitted changes.

```
dev init                                 initialize a git repository here (on main) and create its remote
dev open                                 sync main, checkout or create dev, fast-forward and push
                                         (creates the remote if missing)
dev save -m MSG [--no-add] [--no-push]   commit all changes on dev and push
dev undo [--hard]                        revert the last commit or merge on dev and push;
                                         --hard discards uncommitted changes first
dev release [-m MSG] [options]           bundle backup, squash-merge dev into main, reconcile and push
                                         (creates the remote if missing)
dev release --cancel                     back out of a conflicted release, return to dev
dev release --edit-title -m MSG          amend main's tip title (backup, tags moved, force-with-lease)
dev status [-n LIMIT]                    show branch, dirty files, unpushed counts, last backup,
                                         and the commit graph
dev backup                               write a backup bundle of all refs
dev backup --list                        list backup bundles
dev backup --restore [NAME]              restore a bundle's branches as restore/<stamp>/<branch>
```

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
