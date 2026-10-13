# src/dev/project.cr
require "json"
require "yaml"
require "./cli"
require "./git"
require "./graph"
require "./terminal"
require "./llm"
require "./proposal"

module Dev::Project
  extend self
  include CLI
  include Git

  GRAPH_LIMIT = 30

  TITLE_LIMIT = 72
  TITLE_TAKE  = 3

  SHARD_FILE   = "shard.yml"
  VERSION_KEY  = YAML::Any.new("version")
  VERSION_LINE = /(?m)^(version:[ \t]*)(["']?)[^\s"'#]+\2/
  SHARDS_HOME = "~/.cache/shards/"

  REMOVED = {"switch", "feature", "checkpoint"}

  VISIBILITIES = {"public", "private"}

  VISIBILITY_CONSEQUENCES = "changing visibility can lose stars and watchers, detach public forks, " \
                            "disable push rulesets, and expose GitHub Actions history and logs"

  record TagPlan, name : String, create : Bool, push : Bool

  record RemoteRepo, slug : String, url : String, visibility : String

  COMMANDS = [
    cmd("init", "",
      "initialize a git repository here (on `main`) and create its remote") { -> { cmd_init } },
    cmd("clone", "<owner/name | url> [<dir>]",
      "clone a GitHub repo, then land on dev", arity: 1..2) { |args|
      source = args.positional[0]
      dir    = args.positional[1]?
      -> { cmd_clone(source, dir) }
    },
    cmd("open", "",
      "sync main, checkout or create dev, fast-forward and push (remote auto-created)") { -> { cmd_open } },
    cmd("save", "[-m MSG] [--no-add] [--no-push]",
      "commit all changes on dev and push (message proposed by DeepSeek when -m is omitted in a terminal)",
      [
        Opt.new("message", 'm', "MSG", "commit message (default: proposed in a terminal with $#{LLM::KEY_ENV})"),
        Opt.new("no-add", help: "commit only staged changes"),
        Opt.new("no-push", help: "skip the push"),
      ]) { |args|
      message = args["message"]?
      die "save requires -m MSG" unless message || LLM.available?
      no_add  = args.flag?("no-add")
      no_push = args.flag?("no-push")
      -> { cmd_save(message, no_add, no_push) }
    },
    cmd("undo", "[--hard] [--to REV]",
      "revert the last commit or merge on dev and push, or restore dev's content to REV",
      [
        Opt.new("hard", help: "discard uncommitted changes first"),
        Opt.new("to", value: "REV", help: "restore dev's content to REV as a new commit"),
      ]) { |args|
      hard   = args.flag?("hard")
      target = args["to"]?
      -> { cmd_undo(hard, target) }
    },
    cmd("release", "[-m MSG] [options]",
      "bundle backup, squash-merge dev into main, tag the shard version, reconcile and push (remote auto-created)",
      [
        Opt.new("message", 'm', "MSG", "release title (default: auto-drafted)"),
        Opt.new("dry-run", help: "show the plan without running it"),
        Opt.new("no-tag", help: "skip tagging the shard.yml version"),
        Opt.new("cancel", help: "back out of a conflicted release"),
        Opt.new("edit-title", help: "amend main's tip title; requires -m"),
      ]) { |args|
      message = args["message"]?
      cancel  = args.flag?("cancel")
      edit    = args.flag?("edit-title")
      dry_run = args.flag?("dry-run")
      no_tag  = args.flag?("no-tag")
      die "--cancel takes no message" if cancel && message
      die "--edit-title requires -m MSG" if edit && !message
      die "--no-tag applies only to a release" if no_tag && (cancel || edit)
      -> {
        if cancel
          cmd_release_cancel
        elsif edit
          cmd_edit_title(message.not_nil!, dry_run)
        else
          cmd_release(message, dry_run, no_tag)
        end
      }
    },
    cmd("status", "[-n LIMIT]",
      "show branch, dirty files, unpushed counts, shard version, last backup, and the commit graph",
      [Opt.new("limit", 'n', "LIMIT", "graph depth (default: #{GRAPH_LIMIT})")]) { |args|
      raw   = args["limit"]?
      limit = raw ? (raw.to_i? || die "invalid LIMIT: #{raw}") : GRAPH_LIMIT
      -> { cmd_status(limit) }
    },
    cmd("backup", "[--list] [--restore [NAME]]",
      "write a backup bundle of all refs",
      [
        Opt.new("list", help: "list bundles"),
        Opt.new("restore", help: "restore a bundle's branches and tags"),
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
    cmd("remote", "[--vis public|private | --del]",
      "show origin's slug, URL and visibility; change its visibility or delete it",
      [
        Opt.new("vis", value: "public|private", help: "change visibility of origin's GitHub repo"),
        Opt.new("del", help: "backup bundle, then delete origin's GitHub repo"),
      ]) { |args|
      vis = args["vis"]?
      del = args.flag?("del")
      die "--vis and --del are mutually exclusive" if vis && del
      if vis
        die "invalid visibility `#{vis}`; use `public` or `private`" unless VISIBILITIES.includes?(vis)
        -> { cmd_visibility(vis) }
      elsif del
        -> { cmd_delete_remote }
      else
        -> { cmd_remote }
      end
    },
  ]

  def env_override(name : String) : String?
    ENV["PROJECT_#{name}"]?
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

  def remote_slug(name : String) : String
    env_override("REMOTE") || name
  end

  def ensure_origin!
    return if has_origin?
    die "no `origin` remote and the GitHub CLI (`gh`) is not installed" unless gh_available?
    slug       = remote_slug(repo_name)
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

  def backup_dir(repo : String = repo_name) : Path
    if override = env_override("BACKUP_DIR")
      return Path[override] / repo
    end
    share  = Path.home / ".local" / "share"
    legacy = share / "gitflow" / "backups" / repo
    return legacy if Dir.exists?(legacy.to_s)
    share / "project" / "backups" / repo
  end

  def bundles(dir : Path = backup_dir) : Array(String)
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

  def shard_version(source : String) : String?
    YAML.parse(source).as_h?.try(&.[VERSION_KEY]?).try(&.raw.to_s)
  rescue YAML::ParseException
    nil
  end

  def committed_version(rev : String) : String?
    result = git("show", "#{rev}:#{SHARD_FILE}", check: false, capture: true)
    result.success? ? shard_version(result.stdout) : nil
  end

  def shard_path : Path
    Path[git_stdout("rev-parse", "--show-toplevel")] / SHARD_FILE
  end

  def worktree_version : String?
    path = shard_path
    File.file?(path) ? shard_version(File.read(path)) : nil
  end

  def write_version(version : String) : Nil
    path   = shard_path
    source = File.file?(path) ? File.read(path) : ""
    die "no top-level `version` line in #{SHARD_FILE}" unless source.matches?(VERSION_LINE)
    File.write(path, source.sub(VERSION_LINE) { |_, match| "#{match[1]}#{match[2]}#{version}#{match[2]}" })
    git("add", "--", path.to_s)
  end

  def version_tag(version : String) : String
    "v#{version}"
  end

  def tree_of(commit : String) : String?
    resolve("#{commit}^{tree}")
  end

  def history_anchors(main : String) : Array(String)
    [main, dev_branch].flat_map { |branch| [branch, "origin/#{branch}"] }
  end

  def foreign_tags(main : String, remote : Hash(String, String)) : Array(String)
    anchors = history_anchors(main)
    remote.compact_map do |name, commit|
      anchors.any? { |anchor| ancestor?(commit, anchor) } ? nil : name
    end
  end

  def warn_foreign_tags(main : String, remote : Hash(String, String)?) : Nil
    return unless remote
    foreign = foreign_tags(main, remote)
    return if foreign.empty?
    note "tags on origin point outside this history: #{foreign.map { |tag| "`#{tag}`" }.join(", ")}"
    note "shards consumers resolve these to old code; retag or delete them on origin, then consumers must " \
         "delete their cached copy of this repository under #{SHARDS_HOME} (shards never prunes deleted tags)"
  end

  def tag_commits(name : String, remote : Hash(String, String)?) : {String?, String?}
    {resolve("#{TAG_REF}#{name}^{commit}"), remote.try &.[name]?}
  end

  def plan_tag(version : String, remote : Hash(String, String)?) : TagPlan
    name          = version_tag(version)
    tree          = git_stdout("rev-parse", "#{dev_branch}^{tree}")
    local, shared = tag_commits(name, remote)
    {local, shared}.each do |commit|
      next unless commit
      next if tree_of(commit) == tree
      die "`#{name}` (#{SHARD_FILE} version #{version}) is already released at #{commit[0, 10]} with other content; " \
          "bump `version` in #{SHARD_FILE}, or release with --no-tag"
    end
    TagPlan.new(name, local.nil? && shared.nil?, shared.nil?)
  end

  def tag_steps(plan : TagPlan) : Array(String)
    steps = [] of String
    steps << "tag the release commit `#{plan.name}` (annotated, release title)" if plan.create
    steps << "push tag `#{plan.name}`" if plan.push
    steps << "`#{plan.name}` already tagged with this content; no new tag" unless plan.create || plan.push
    steps
  end

  def apply_tag(plan : TagPlan, title : String) : Nil
    if plan.create
      git("tag", "-a", plan.name, "-m", title)
      ok "tagged `#{plan.name}`"
    end
    if plan.push
      git("push", "origin", "#{TAG_REF}#{plan.name}")
      ok "pushed tag `#{plan.name}`"
    end
  end

  def version_state(version : String) : String
    name   = version_tag(version)
    remote = has_origin? ? remote_tags : nil
    local  = resolve("#{TAG_REF}#{name}^{commit}")
    shared = remote.try &.[name]?
    where  = if has_origin? && remote.nil?
               " (origin unreachable)"
             elsif local && !shared
               " (local only, not pushed)"
             else
               ""
             end
    tagged = shared || local
    return Theme.muted("#{name} not yet released#{where}").to_s unless tagged
    tree = tree_of(tagged)
    return Theme.warn("#{name} points outside this history#{where}").to_s unless tree
    head = local_branch_exists?(dev_branch) ? dev_branch : "HEAD"
    if tree == tree_of(head)
      Theme.ok("#{name} released#{where}").to_s
    else
      Theme.warn("#{name} released; `#{head}` changed since — bump `version` before the next release#{where}").to_s
    end
  end

  def cmd_init : Int32
    die "already inside a git repository" if in_repo?
    name = Path[Dir.current].basename
    dir  = backup_dir(name)
    if latest = bundles(dir).last?
      die "backup bundles for `#{name}` exist in #{dir}; restore that history with " \
          "`git clone #{latest}` instead of starting a new one"
    end
    slug = remote_slug(name)
    if gh_available? && gh_repo_exists?(slug)
      die "GitHub repo `#{slug}` already exists; clone it instead of starting a new history"
    end
    main = default_main_branch
    git("init", "-b", main)
    git("commit", "--allow-empty", "-m", "initial commit")
    push main
    ok "initialized `#{main}`; run `dev open` to start work on `#{dev_branch}`"
    0
  end

  def clone_dir(source : String) : String
    Path[source.rchop('/')].basename.rchop(".git")
  end

  def cmd_clone(source : String, dir : String?) : Int32
    die "already inside a git repository" if in_repo?
    require_gh
    target = dir || clone_dir(source)
    die "`#{target}` already exists" if File.exists?(target)
    gh("repo", "clone", source, target)
    status = Dir.cd(target) { cmd_open }
    info "cloned into `#{target}`; run `cd #{target}`"
    status
  end

  def origin_repo : RemoteRepo
    die "no `origin` remote" unless has_origin?
    require_gh
    url  = git_stdout("remote", "get-url", "origin")
    json = JSON.parse(gh("repo", "view", url, "--json", "nameWithOwner,visibility", capture: true).stdout)
    RemoteRepo.new(json["nameWithOwner"].as_s, url, json["visibility"].as_s.downcase)
  end

  def cmd_remote : Int32
    require_repo
    repo = origin_repo
    puts "#{Theme.heading("slug:")} #{Theme.accent(repo.slug)}"
    puts "#{Theme.heading("url:")} #{repo.url}"
    puts "#{Theme.heading("visibility:")} #{repo.visibility}"
    0
  end

  def cmd_visibility(visibility : String) : Int32
    require_repo
    repo = origin_repo
    if repo.visibility == visibility
      info "`#{repo.slug}` is already #{visibility}"
      return 0
    end
    note VISIBILITY_CONSEQUENCES
    gh("repo", "edit", repo.slug, "--visibility", visibility, "--accept-visibility-change-consequences")
    ok "`#{repo.slug}` is now #{visibility} (was #{repo.visibility})"
    0
  end

  def cmd_delete_remote : Int32
    require_repo
    repo = origin_repo
    git("fetch", "--tags", "origin")
    make_bundle
    if tags = remote_tags
      unless tags.empty?
        note "tags published on origin: #{tags.keys.map { |tag| "`#{tag}`" }.join(", ")}"
        note "shards consumers lose these releases and must delete their cached copy of this repository " \
             "under #{SHARDS_HOME} (shards never prunes deleted tags)"
      end
    end
    unless gh("repo", "delete", repo.slug, check: false).success?
      die "deleting `#{repo.slug}` failed; if the token lacks the `delete_repo` scope, " \
          "run `gh auth refresh -h github.com -s delete_repo`"
    end
    ok "deleted GitHub repo `#{repo.slug}`; local history is untouched and backed up"
    note "`origin` still points at the deleted repo, so pushes fail; `git remote remove origin` " \
         "lets the next push create a new GitHub repo"
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
    elsif remote_branch_exists?(dev_branch)
      git("checkout", "-b", dev_branch, "--track", "origin/#{dev_branch}")
      info "checked out `#{dev_branch}` from `origin/#{dev_branch}`"
    else
      git("checkout", "-b", dev_branch)
      info "created `#{dev_branch}` from `#{main}`"
    end
    git("pull", "--ff-only", "origin", dev_branch) if remote_branch_exists?(dev_branch)
    push dev_branch
    warn_foreign_tags(main, remote_tags)
    ok "now on `#{dev_branch}`; save with `dev save -m ...`, release with `dev release`"
    0
  end

  def cmd_save(message : String?, no_add : Bool, no_push : Bool) : Int32
    require_repo
    require_dev "save"
    git("add", "-A") unless no_add
    die "nothing to commit" if git("diff", "--cached", "--quiet", check: false).success?
    git("commit", "-m", message || propose_save_message)
    if no_push
      info "committed (not pushed; --no-push)"
    else
      push dev_branch
    end
    0
  end

  def propose_save_message : String
    version  = worktree_version
    remote   = version && has_origin? ? remote_tags : nil
    released = version ? tag_commits(version_tag(version), remote).any? : false
    context  = Proposal.staged(version, released)
    draft    = Proposal.request(context) ||
               die "no proposal; your changes are staged — save with -m MSG"
    accepted = Proposal.confirm(context, draft) ||
               die "proposal declined; nothing committed (your changes stay staged)"
    if bumped = context.target(accepted.bump)
      write_version(bumped)
      info "`#{SHARD_FILE}` version set to `#{bumped}`"
    end
    accepted.message
  end

  def cmd_undo(hard : Bool, target : String?) : Int32
    require_repo
    require_dev "undo"
    require_clean "undo" unless hard
    source    = target.try { |rev| restore_source(rev) }
    discarded = hard && discard_changes
    done, kept = source ? restore_to(source) : revert_last
    push dev_branch
    ok "#{done}#{discarded ? "; uncommitted changes discarded" : ""}; #{kept}"
    0
  end

  def discard_changes : Bool
    dirty = dirty_files
    return false if dirty.empty?
    STDERR.puts Theme.warn("uncommitted changes (#{dirty.size} paths); discarding (--hard):")
    dirty.first(20).each { |line| STDERR.puts "  #{line}" }
    git("reset", "--hard", "HEAD")
    git("clean", "-fd")
    true
  end

  def revert_last : {String, String}
    subject = git_stdout("log", "-1", "--format=%h %s")
    parents = git_stdout("rev-list", "--parents", "-n", "1", "HEAD").split.size - 1
    if parents > 1
      git("revert", "--no-edit", "-m", "1", "HEAD")
    else
      git("revert", "--no-edit", "HEAD")
    end
    {"reverted `#{subject}` on `#{dev_branch}`", "the original commit stays in history"}
  end

  def restore_source(rev : String) : String
    sha = resolve("#{rev}^{commit}") || die "`#{rev}` is not a commit"
    if tree_of(sha) == tree_of("HEAD")
      die "`#{dev_branch}` already matches `#{rev}`; nothing to restore"
    end
    unless ancestor?(sha, dev_branch)
      note "`#{sha[0, 10]}` is not in `#{dev_branch}`'s history; restoring its content anyway"
    end
    sha
  end

  def restore_to(sha : String) : {String, String}
    label = git_stdout("log", "-1", "--format=%h (%s)", sha)
    git("restore", "--source=#{sha}", "--staged", "--worktree", "--", ":/")
    git("commit", "-m", "restore to #{label}")
    {"restored `#{dev_branch}` to `#{label}`", "later commits stay in history"}
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

  def cmd_release(message : String?, dry_run : Bool, no_tag : Bool) : Int32
    require_repo
    require_clean "release"
    main    = main_branch
    current = current_branch
    if current != dev_branch
      note "releasing from `#{current}`; `#{dev_branch}` is what gets merged into `#{main}`"
    end
    git("fetch", "origin") if has_origin?
    remote = has_origin? ? remote_tags : nil
    warn_foreign_tags(main, remote)
    title   = message || (pending_changes?(main) ? auto_release_title(main) : nil)
    version = title && !no_tag ? committed_version(dev_branch) : nil
    plan    = version ? plan_tag(version, remote) : nil
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
    ]
    steps.concat(tag_steps(plan)) if plan
    steps << "checkout `#{dev_branch}`, reconcile with `merge -s ours #{main}`"
    steps << "push every local branch"
    steps.unshift("create GitHub remote repo (`origin`)") unless has_origin?
    if dry_run
      puts Theme.heading("dry run; would:")
      steps.each_with_index { |step, i| info "  #{i + 1}. #{step}" }
      return 0
    end
    make_bundle
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
      plan.try { |tag| apply_tag(tag, final) }
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
      if git_stdout("cat-file", "-t", "#{TAG_REF}#{tag}") == "tag"
        git("tag", "-f", "-a", tag, "-m", message)
      else
        git("tag", "-f", tag)
      end
      git("push", "--force", "origin", "#{TAG_REF}#{tag}")
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
    git("fetch", "--no-tags", file,
      "refs/heads/*:refs/heads/#{prefix}*", "#{TAG_REF}*:#{TAG_REF}#{prefix}*",
      "^refs/heads/restore/*", "^#{TAG_REF}restore/*")
    puts "#{Theme.heading("restored from")} #{file}:"
    local_branches(prefix).each { |b| puts "  #{Theme.accent(b)}" }
    local_tags(prefix).each { |t| puts "  #{Theme.accent(t)} #{Theme.muted("(tag)")}" }
    info "existing branches and tags were not changed"
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
    if version = worktree_version
      puts "#{Theme.heading("version:")} #{version_state(version)}"
    end
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