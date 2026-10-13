# src/dev/insight.cr
require "json"
require "semantic_version"
require "./cli"
require "./git"
require "./diff"
require "./llm"
require "./project"
require "./terminal"

module Dev::Insight
  extend self
  include CLI
  include Git

  FIND_LIMIT = 200
  LOG_LIMIT  = 60_000
  MIN_SHA    = 7
  MIN_WRAP   = 20

  NOTE_SECTIONS = {
    "breaking" => "Breaking",
    "added"    => "Added",
    "changed"  => "Changed",
    "fixed"    => "Fixed",
  }

  FIND_SYSTEM = <<-PROMPT
  You locate one git commit from a description.
  The user gives a description and a git log, newest first; each entry starts with "commit <sha> <date> <subject>", followed by the files it changed.
  Reply with a single json object in exactly this shape:
  {"commit": "<full sha from the log, or an empty string when nothing matches>", "reason": "one short sentence"}
  When the description names a state ("before X", "when Y still worked"), answer the newest commit that has that state, such as the commit just before X.
  PROMPT

  EXPLAIN_SYSTEM = <<-PROMPT
  You explain git changes to the developer who made them.
  Reply with a single json object in exactly this shape:
  {"summary": "two or three sentences on what changed and why it matters", "changes": ["one concrete change per item"]}
  Be specific about behavior and name the modules, commands, and functions involved; skip trivia such as formatting.
  PROMPT

  NOTES_SYSTEM = <<-PROMPT
  You write release notes for the users of a project.
  Reply with a single json object in exactly this shape:
  {"breaking": ["..."], "added": ["..."], "changed": ["..."], "fixed": ["..."]}
  Each item is one line describing a user-visible effect, not a file edit. Leave a list empty when nothing fits it.
  PROMPT

  struct Match
    include JSON::Serializable

    getter commit : String = ""
    getter reason : String = ""
  end

  struct Explanation
    include JSON::Serializable

    getter summary : String = ""
    getter changes : Array(String) = [] of String
  end

  COMMANDS = [
    cmd("find", "<description>... [-n LIMIT]",
      "find the commit a description refers to (DeepSeek)",
      [Opt.new("limit", 'n', "LIMIT", "commits to search (default: #{FIND_LIMIT})")],
      arity: 1..Int32::MAX) { |args|
      raw   = args["limit"]?
      limit = raw ? (raw.to_i?.try { |count| count if count > 0 } || die "invalid LIMIT: #{raw}") : FIND_LIMIT
      description = args.positional.join(' ')
      -> { cmd_find(description, limit) }
    },
    cmd("explain", "[<rev> | <range>]",
      "explain a commit or range in plain language (DeepSeek; default: unreleased work on dev, else HEAD)",
      arity: 0..1) { |args|
      target = args.positional[0]?
      -> { cmd_explain(target) }
    },
    cmd("notes", "[<tag>]",
      "draft markdown release notes for a v<version> tag (DeepSeek; default: the latest)",
      arity: 0..1) { |args|
      tag = args.positional[0]?
      -> { cmd_notes(tag) }
    },
  ]

  def cmd_find(description : String, limit : Int32) : Int32
    require_repo
    LLM.require_key
    dev    = Project.dev_branch
    branch = local_branch_exists?(dev) ? dev : "HEAD"
    count  = limit.to_s
    shas   = git_stdout("log", "--no-merges", "-n", count, "--format=%H", branch).lines
    die "no commits on `#{branch}`" if shas.empty?
    log = git_stdout("log", "--no-merges", "-n", count, "--date=short",
      "--format=%ncommit %H %ad %s", "--name-status", branch)
    reply = parse(Match, ask(FIND_SYSTEM,
      "description: #{description}\n\ngit log of `#{branch}`:\n#{Diff.clip(log, LOG_LIMIT)}\n"))
    pick = reply.commit.strip.downcase
    die "no commit matches#{reply.reason.empty? ? "" : ": #{reply.reason}"}" if pick.empty?
    sha = pick.size >= MIN_SHA ? shas.find(&.starts_with?(pick)) : nil
    die "DeepSeek answered `#{pick}`, which is not among the #{shas.size} searched commits" unless sha
    puts "#{Theme.heading("match:")} #{git_stdout("log", "-1", "--date=short", "--format=%h %ad %s", sha)}"
    puts "#{Theme.heading("reason:")} #{reply.reason}" unless reply.reason.empty?
    info "restore its content with `dev undo --to #{sha[0, 10]}`"
    0
  end

  def cmd_explain(target : String?) : Int32
    require_repo
    LLM.require_key
    spec = target || default_target
    if spec.includes?("..")
      commits = git_stdout("log", "--no-merges", "--format=%h %s", spec)
      die "no commits in `#{spec}`" if commits.empty?
      header  = "#{spec} (#{commits.lines.size} commits)"
      base    = ["diff", spec]
      context = "commits:\n#{commits}\n"
    else
      sha     = resolve("#{spec}^{commit}") || die "`#{spec}` is not a commit"
      header  = git_stdout("log", "-1", "--format=%h %s", sha)
      base    = ["show", "--format=", "--diff-merges=first-parent", sha]
      context = "commit:\n#{git_stdout("show", "-s", "--date=short", "--format=%h %ad%n%B", sha)}\n"
    end
    stat = Diff.stat(base)
    die "`#{spec}` changes no files" if stat.blank?
    reply = parse(Explanation, ask(EXPLAIN_SYSTEM,
      "#{context}\ndiff stat:\n#{stat}\n\ndiff:\n#{Diff.patch(base)}\n"))
    width = Dev::Terminal.wrap_width(80)
    puts "#{Theme.heading("explain:")} #{header}"
    puts
    emit(reply.summary.strip, "", width)
    changes = reply.changes.map(&.strip).reject(&.empty?)
    unless changes.empty?
      puts
      changes.each { |change| emit(change, "  - ", width) }
    end
    0
  end

  def cmd_notes(tag : String?) : Int32
    require_repo
    LLM.require_key
    releases = local_tags
      .compact_map { |name| name.starts_with?('v') ? SemanticVersion.parse?(name[1..]).try { |version| {version, name} } : nil }
      .sort_by!(&.[0])
    die "no `v<version>` tags; release first" if releases.empty?
    index = if tag
              wanted = tag.starts_with?('v') ? tag : "v#{tag}"
              releases.index { |(_, name)| name == wanted } || die "tag `#{wanted}` not found (see `git tag`)"
            else
              releases.size - 1
            end
    name     = releases[index][1]
    previous = index > 0 ? releases[index - 1][1] : nil
    base     = ["diff", previous || git_stdout("hash-object", "-t", "tree", "/dev/null"), name]
    titles   = git_stdout("log", "--no-merges", "--format=- %s", previous ? "#{previous}..#{name}" : name)
    sections = parse(Hash(String, Array(String)), ask(NOTES_SYSTEM,
      "release: #{name} (previous release: #{previous || "none"})\n\nrelease commits:\n#{titles}\n\n" \
      "diff stat:\n#{Diff.stat(base)}\n\ndiff:\n#{Diff.patch(base)}\n"))
    date = git_stdout("log", "-1", "--date=short", "--format=%ad", name)
    puts "## #{name} (#{date})"
    NOTE_SECTIONS.each do |key, heading|
      items = sections[key]?.try(&.map(&.strip).reject(&.empty?)) || next
      next if items.empty?
      puts
      puts "### #{heading}"
      puts
      items.each { |item| puts "- #{item}" }
    end
    0
  end

  private def default_target : String
    dev = Project.dev_branch
    return "HEAD" unless local_branch_exists?(dev)
    main = main_branch
    Project.pending_changes?(main) ? "#{main}..#{dev}" : "HEAD"
  end

  private def ask(system : String, user : String) : String
    STDERR.puts Theme.markup("asking DeepSeek (`#{LLM.model}`)…")
    completion = LLM.complete(system, user)
    STDERR.puts Theme.muted(LLM.label(completion.usage))
    completion.content
  rescue ex : LLM::Failure
    die "DeepSeek request failed: #{ex.message}"
  end

  private def parse(type : T.class, content : String) : T forall T
    T.from_json(content)
  rescue ex : JSON::ParseException
    die "unexpected reply from DeepSeek: #{ex.message}"
  end

  private def emit(text : String, lead : String, width : Int32?)
    rest  = " " * lead.size
    lines = width && width - lead.size >= MIN_WRAP ? wrap_text(text, width - lead.size) : [text]
    lines.each_with_index { |line, i| puts "#{i == 0 ? lead : rest}#{line}" }
  end
end
