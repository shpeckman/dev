# src/dev/project.cr
require "./cli"
require "./git"
require "./graph"
require "./terminal"

module Dev::Project
  extend self
  include CLI
  include Git

  GRAPH_LIMIT = 30

  TITLE_LIMIT = 72
  TITLE_TAKE  = 3

  REMOVED = {"switch", "feature", "checkpoint"}

  COMMANDS = [
    cmd("init", "",
      "initialize a git repository here (on `main`) and create its remote") { -> { cmd_init } },
    cmd("open", "",
      "sync main, checkout or create dev, fast-forward and push (remote auto-created)") { -> { cmd_open } },
    cmd("save", "-m MSG [--no-add] [--no-push]",
      "commit all changes on dev and push",
      [
        Opt.new("message", 'm', "MSG", "commit message", required: true),
        Opt.new("no-add", help: "commit only staged changes"),
        Opt.new("no-push", help: "skip the push"),
      ]) { |args|
      message = args["message"]
      no_add  = args.flag?("no-add")
      no_push = args.flag?("no-push")
      -> { cmd_save(message, no_add, no_push) }
    },
    cmd("undo", "[--hard]",
      "revert the last commit or merge on dev and push",
      [
        Opt.new("hard", help: "discard uncommitted changes first"),
      ]) { |args|
      hard = args.flag?("hard")
      -> { cmd_undo(hard) }
    },
    cmd("release", "[-m MSG] [options]",
      "bundle backup, squash-merge dev into main, reconcile and push (remote auto-created)",
      [
        Opt.new("message", 'm', "MSG", "release title (default: auto-drafted)"),
        Opt.new("dry-run", help: "show the plan without running it"),
        Opt.new("cancel", help: "back out of a conflicted release"),
        Opt.new("edit-title", help: "amend main's tip title; requires -m"),
      ]) { |args|
      message = args["message"]?
      cancel  = args.flag?("cancel")
      edit    = args.flag?("edit-title")
      dry_run = args.flag?("dry-run")
      die "--cancel takes no message" if cancel && message
      die "--edit-title requires -m MSG" if edit && !message
      -> {
        if cancel
          cmd_release_cancel
        elsif edit
          cmd_edit_title(message.not_nil!, dry_run)
        else
          cmd_release(message, dry_run)
        end
      }
    },
    cmd("status", "[-n LIMIT]",
      "show branch, dirty files, unpushed counts, last backup, and the commit graph",
      [Opt.new("limit", 'n', "LIMIT", "graph depth (default: #{GRAPH_LIMIT})")]) { |args|
      raw   = args["limit"]?
      limit = raw ? (raw.to_i? || die "invalid LIMIT: #{raw}") : GRAPH_LIMIT
      -> { cmd_status(limit) }
    },
    cmd("backup", "[--list] [--restore [NAME]]",
      "write a backup bundle of all refs",
      [
        Opt.new("list", help: "list bundles"),
        Opt.new("restore", help: "restore a bundle's branches"),
      ], arity: 0..1) { |args|
      name = args.positional[0]?
      if args.flag?("list")
        die "--list takes no argument" if name
        -> { cmd_backups }
      elsif args.flag?("restore")
        -> { cmd_restore(name) }
      else
        die "backup takes no arguments; see `dev backup --help`" if name
        -> { cmd_backup }
      end
    },
  ]

  def env_override(name : String) : String?
    ENV["PROJECT_#{name}"]?
  end

  def require_repo
    die "not inside a git repository" unless in_repo?
  end

  def require_branch : String
    branch = current_branch
    die "detached HEAD; checkout a branch first" if branch.empty?
    branch
  end

  def dirty_files : Array(String)
    git_stdout("status", "--porcelain").lines
  end

  def require_clean(action : String)
    dirty = dirty_files
    return if dirty.empty?
    STDERR.puts Theme.warn("uncommitted changes (#{dirty.size} paths); commit or stash first:")
    dirty.first(20).each { |line| STDERR.puts "  #{line}" }
    die "refusing to #{action} on a dirty tree"
  end

  def require_clean_tracked(action : String)
    dirty = dirty_files.reject { |line| line.starts_with?("??") }
    return if dirty.empty?
    STDERR.puts Theme.warn("uncommitted changes (#{dirty.size} paths); commit or stash first:")
    dirty.first(20).each { |line| STDERR.puts "  #{line}" }
    die "refusing to #{action} on a dirty tree"
  end

  def require_dev(action : String)
    branch = require_branch
    return if branch == dev_branch
    if branch == main_branch
      die "`#{branch}` is release-only; run `dev open`"
    end
    die "cannot #{action} on `#{branch}`; work happens on `#{dev_branch}` — run `dev open`"
  end

  def ensure_origin!
    return if has_origin?
    die "no `origin` remote and the GitHub CLI (`gh`) is not installed" unless gh_available?
    slug       = env_override("REMOTE") || repo_name
    top        = git_stdout("rev-parse", "--show-toplevel")
    visibility = env_override("PUBLIC") == "1" ? "--public" : "--private"
    info "no `origin` remote; creating GitHub repo `#{slug}`"
    gh("repo", "create", slug, "--source=#{top}", "--remote=origin", visibility)
    ok "created GitHub repo `#{slug}`; `origin` set"
  end

  def push(branch : String)
    ensure_origin!
    git("push", "-u", "origin", branch)
  end

  def dev_branch : String
    env_override("DEV") || "dev"
  end

  def default_main_branch : String
    if override = env_override("MAIN")
      return override unless override.empty?
    end
    "main"
  end

  def repo_name : String
    Path[git_stdout("rev-parse", "--show-toplevel")].basename
  end

  def backup_dir : Path
    repo = repo_name
    if override = env_override("BACKUP_DIR")
      return Path[override] / repo
    end
    share  = Path.home / ".local" / "share"
    legacy = share / "gitflow" / "backups" / repo
    return legacy if Dir.exists?(legacy.to_s)
    share / "project" / "backups" / repo
  end

  def bundles : Array(String)
    dir = backup_dir
    Dir.exists?(dir.to_s) ? Dir.glob("#{dir}/*.bundle").sort : [] of String
  end

  def make_bundle : Path
    dir = backup_dir
    Dir.mkdir_p(dir.to_s)
    file = dir / "#{Time.local.to_s("%Y%m%d-%H%M%S")}.bundle"
    git("bundle", "create", file.to_s, "--all")
    info "backup bundle: #{file}  (restore: dev backup --restore #{file.basename})"
    file
  end

  def resolve_bundle(name : String?) : String
    dir = backup_dir
    unless name
      return bundles.last? || die "no backup bundles in #{dir}"
    end
    candidates = {name, (dir / name).to_s, (dir / "#{name}.bundle").to_s}
    candidates.find { |path| File.file?(path) } || die "bundle `#{name}` not found (see `dev backup --list`)"
  end

  def checkout(branch : String)
    git("checkout", branch)
  end

  def cmd_init : Int32
    die "already inside a git repository" if in_repo?
    main = default_main_branch
    git("init", "-b", main)
    git("commit", "--allow-empty", "-m", "initial commit")
    push main
    ok "initialized `#{main}`; run `dev open` to start work on `#{dev_branch}`"
    0
  end

  def cmd_open : Int32
    require_repo
    require_clean_tracked "open"
    ensure_origin!
    main = main_branch
    git("fetch", "origin")
    checkout main unless current_branch == main
    git("pull", "--ff-only", "origin", main) if remote_branch_exists?(main)
    if local_branch_exists?(dev_branch)
      checkout dev_branch
      info "on existing `#{dev_branch}` (from `#{main}`)"
    else
      git("checkout", "-b", dev_branch)
      info "created `#{dev_branch}` from `#{main}`"
    end
    git("pull", "--ff-only", "origin", dev_branch) if remote_branch_exists?(dev_branch)
    push dev_branch
    ok "now on `#{dev_branch}`; save with `dev save -m ...`, release with `dev release`"
    0
  end

  def cmd_save(message : String, no_add : Bool, no_push : Bool) : Int32
    require_repo
    require_dev "save"
    git("add", "-A") unless no_add
    die "nothing to commit" if git("diff", "--cached", "--quiet", check: false).success?
    git("commit", "-m", message)
    if no_push
      info "committed (not pushed; --no-push)"
    else
      push dev_branch
    end
    0
  end

  def cmd_undo(hard : Bool) : Int32
    require_repo
    require_dev "undo"
    dirty = [] of String
    if hard
      dirty = dirty_files
      unless dirty.empty?
        STDERR.puts Theme.warn("uncommitted changes (#{dirty.size} paths); discarding (--hard):")
        dirty.first(20).each { |line| STDERR.puts "  #{line}" }
        git("reset", "--hard", "HEAD")
        git("clean", "-fd")
      end
    else
      require_clean "undo"
    end
    subject = git_stdout("log", "-1", "--format=%h %s")
    parents = git_stdout("rev-list", "--parents", "-n", "1", "HEAD").split.size - 1
    if parents > 1
      git("revert", "--no-edit", "-m", "1", "HEAD")
    else
      git("revert", "--no-edit", "HEAD")
    end
    push dev_branch
    if hard && !dirty.empty?
      ok "reverted `#{subject}` on `#{dev_branch}`; uncommitted changes discarded; the original commit stays in history"
    else
      ok "reverted `#{subject}` on `#{dev_branch}`; the original commit stays in history"
    end
    0
  end

  def pending_changes?(main : String) : Bool
    !git("diff", "--quiet", main, dev_branch, check: false).success?
  end

  def pending_subjects(main : String) : Array(String)
    git_stdout("log", "--no-merges", "--format=%s", "#{main}..#{dev_branch}").lines
  end

  def auto_release_title(main : String) : String
    date     = Time.local.to_s("%Y-%m-%d")
    subjects = pending_subjects(main)
    return "release #{date}" if subjects.empty?
    titles = subjects.first(TITLE_TAKE)
    extra  = subjects.size - titles.size
    loop do
      title = "release #{date}: #{titles.join("; ")}"
      title = "#{title}; + #{extra} more" if extra > 0
      return title if title.size <= TITLE_LIMIT
      return "#{title[0, TITLE_LIMIT - 2].rstrip.rstrip(';')}…" if titles.size == 1
      titles = titles[0...-1]
      extra += 1
    end
  end

  def cmd_release(message : String?, dry_run : Bool) : Int32
    require_repo
    require_clean "release"
    main    = main_branch
    current = current_branch
    if current != dev_branch
      note "releasing from `#{current}`; `#{dev_branch}` is what gets merged into `#{main}`"
    end
    title = message || (pending_changes?(main) ? auto_release_title(main) : nil)
    commit_step = if title
                    "squash-merge `#{dev_branch}` into `#{main}`, commit: #{title.inspect}"
                  else
                    "squash-merge `#{dev_branch}` into `#{main}` (nothing new; `#{main}` unchanged)"
                  end
    steps = [
      "bundle all refs to #{backup_dir}/",
      "checkout `#{main}`, pull --ff-only",
      commit_step,
      "push `#{main}`",
      "checkout `#{dev_branch}`, reconcile with `merge -s ours #{main}`",
      "push every local branch",
    ]
    steps.unshift("create GitHub remote repo (`origin`)") unless has_origin?
    if dry_run
      puts Theme.heading("dry run; would:")
      steps.each_with_index { |step, i| info "  #{i + 1}. #{step}" }
      return 0
    end
    make_bundle
    git("fetch", "origin") if has_origin?
    checkout main
    git("pull", "--ff-only", "origin", main) if remote_branch_exists?(main)
    unless git("merge", "--squash", dev_branch, check: false).success?
      die "squash merge of `#{dev_branch}` into `#{main}` has conflicts; resolve manually, " \
          "then commit and push, or back out with `dev release --cancel`. " \
          "Full backup is in #{backup_dir}"
    end
    if git("diff", "--cached", "--quiet", check: false).success?
      info "nothing new on `#{dev_branch}`; `#{main}` unchanged"
    else
      final = message || auto_release_title(main)
      git("commit", "-m", final)
      push main
      if message
        ok "`#{main}` updated: one clean commit for this release"
      else
        ok "`#{main}` updated: #{final}"
        note "title auto-drafted from save messages; fix with `dev release --edit-title -m \"...\"`"
      end
    end
    checkout dev_branch
    git("merge", "-s", "ours", "-m",
      "reconcile #{main} into #{dev_branch} after release", main)
    ensure_origin!
    local_branches.each { |b| git("push", "-u", "origin", b) }
    ok "all branches pushed; full history preserved on origin"
    ok "now on `#{dev_branch}`"
    0
  end

  def cmd_release_cancel : Int32
    require_repo
    main   = main_branch
    branch = current_branch
    unless branch == main
      die "--cancel backs out a conflicted release on `#{main}`; you are on `#{branch}`"
    end
    marker = git_stdout("rev-parse", "--git-path", "SQUASH_MSG")
    die "no squash merge in progress on `#{main}`; nothing to cancel" unless File.exists?(marker)
    git("reset", "--merge")
    checkout dev_branch
    ok "release backed out; `#{main}` is untouched; now on `#{dev_branch}`"
    0
  end

  def cmd_edit_title(message : String, dry_run : Bool) : Int32
    require_repo
    require_clean "edit the title"
    ensure_origin!
    main = main_branch
    git("fetch", "origin")
    checkout main
    git("pull", "--ff-only", "origin", main) if remote_branch_exists?(main)

    tip     = git_stdout("rev-parse", main)
    subject = git_stdout("log", "-1", "--format=%s", main)
    tags    = git_stdout("tag", "--points-at", tip).lines

    steps = [
      "bundle all refs to #{backup_dir}/",
      "amend the message of `#{main}` tip #{tip[0, 10]} (#{subject.inspect})",
      "force-push `#{main}` with --force-with-lease",
    ]
    steps << "move tags onto the new tip: #{tags.join(", ")}" unless tags.empty?
    steps << "checkout `#{dev_branch}`, reconcile with `merge -s ours #{main}`"
    steps << "push `#{dev_branch}`"
    if dry_run
      puts Theme.heading("dry run; would:")
      steps.each_with_index { |step, i| info "  #{i + 1}. #{step}" }
      return 0
    end

    make_bundle
    git("commit", "--amend", "-m", message)
    git("push", "--force-with-lease", "origin", main)
    ok "`#{main}` tip reworded (was #{tip[0, 10]})"
    tags.each do |tag|
      git("tag", "-f", tag)
      git("push", "--force", "origin", "refs/tags/#{tag}")
      info "tag `#{tag}` moved and force-pushed"
    end

    checkout dev_branch
    git("merge", "-s", "ours", "-m",
      "reconcile #{main} into #{dev_branch} after edit-title", main)
    push dev_branch
    ok "now on `#{dev_branch}`"
    0
  end

  def cmd_backup : Int32
    require_repo
    make_bundle
    0
  end

  def cmd_backups : Int32
    require_repo
    all = bundles
    if all.empty?
      info "no backup bundles in #{backup_dir}"
    else
      all.each { |file| puts file }
    end
    0
  end

  def cmd_restore(name : String?) : Int32
    require_repo
    file   = resolve_bundle(name)
    prefix = "restore/#{Path[file].stem}/"
    git("bundle", "verify", file, capture: true)
    git("fetch", file, "refs/heads/*:refs/heads/#{prefix}*", "^refs/heads/restore/*")
    puts "#{Theme.heading("restored from")} #{file}:"
    local_branches(prefix).each { |b| puts "  #{Theme.accent(b)}" }
    info "existing branches were not changed"
    0
  end

  def cmd_status(limit : Int32) : Int32
    require_repo
    branch = current_branch
    branch = "(detached HEAD)" if branch.empty?
    dirty  = dirty_files
    puts "#{Theme.heading("on:")} #{Theme.accent(branch)}"
    puts "#{Theme.heading("dirty:")} #{dirty.empty? ? Theme.ok("0 paths (clean)") : Theme.warn("#{dirty.size} paths")}"
    dirty.first(15).each { |line| puts "  #{line}" }
    puts "\n#{Theme.heading("branches (ahead of origin):")}"
    local_branches.each do |b|
      if remote_branch_exists?(b)
        n = git_stdout("rev-list", "--count", "origin/#{b}..#{b}")
        puts "  #{Theme.accent(b)}: #{n == "0" ? Theme.muted("+0 unpushed") : Theme.warn("+#{n} unpushed")}"
      else
        puts "  #{Theme.accent(b)}: #{Theme.warn("not on origin")}"
      end
    end
    all = bundles
    puts "\n#{Theme.heading("last backup bundle:")} #{all.last}" unless all.empty?
    puts "\n#{Theme.heading("graph:")}"
    lines = git_stdout("log", "--graph", "--all", "--color=never",
      "--format=#{Dev::Graph::FORMAT}", "-n", limit.to_s).lines
    puts Dev::Graph.render(lines, graph_width)
    0
  end

  def graph_width : Int32?
    Dev::Terminal.wrap_width(nil)
  end
end
