# src/dev/proposal.cr
require "json"
require "semantic_version"
require "./cli"
require "./git"
require "./diff"
require "./llm"

module Dev::Proposal
  extend self
  include CLI
  include Git

  MESSAGE_LIMIT = 72
  STYLE_LIMIT   = 20
  STYLE_SKIP    = {"Revert \"", "restore to ", "bump version to ", "initial commit"}
  DOC_FILES     = {"README.md", "AGENTS.md", "SKILL.md"}
  SOURCE_PREFIX = "src/"
  DOCS_LIMIT    = 20_000

  enum Bump
    None
    Patch
    Minor
    Major

    def apply(version : SemanticVersion) : SemanticVersion
      case self
      in .none?  then version
      in .patch? then version.bump_patch
      in .minor? then version.bump_minor
      in .major? then version.bump_major
      end
    end

    def label : String
      to_s.downcase
    end
  end

  SYSTEM = <<-PROMPT
  You write git commit messages and judge semantic version bumps.
  Reply with a single json object in exactly this shape:
  {"message": "add a dry-run flag to release", "bump": "patch", "reason": "one short sentence", "docs": []}
  message: one line, at most #{MESSAGE_LIMIT} characters, imperative mood, lower-case first letter, no trailing period; say what changed and why, not which files. When the user lists recent commit subjects, match their style.
  bump: one of the allowed values listed by the user, following Semantic Versioning 2.0.0. While the major version is 0, breaking changes are "minor" and everything else is "patch". Choose the smallest allowed value that fits.
  reason: why that bump fits, in one short sentence.
  docs: only when the user includes documentation files, list each statement in them that the staged changes make wrong or incomplete, as "FILE: what to update"; otherwise an empty list.
  PROMPT

  record Context, stat : String, patch : String, version : SemanticVersion?, bumpable : Bool,
    style : Array(String), docs : Array({String, String}) do
    def bumps : Array(Bump)
      bumpable ? Bump.values : [Bump::None]
    end

    def target(bump : Bump) : String?
      return nil if bump.none? || !bumpable
      version.try { |current| bump.apply(current).to_s }
    end
  end

  record Draft, message : String, bump : Bump, reason : String, stale : Array(String), usage : LLM::Usage?

  struct Reply
    include JSON::Serializable

    getter message : String
    getter bump : String = "none"
    getter reason : String = ""
    getter docs : Array(String) = [] of String
  end

  def staged(version : String?, bumpable : Bool) : Context
    semver = version.try { |raw| SemanticVersion.parse?(raw) }
    if version && semver.nil?
      note "`#{version}` in shard.yml is not a semantic version; proposing a message only"
      bumpable = false
    end
    base = ["diff", "--cached"]
    Context.new(Diff.stat(base), Diff.patch(base), semver, bumpable, recent_subjects, doc_sources)
  end

  def request(context : Context) : Draft?
    info "asking DeepSeek (`#{LLM.model}`) for a proposal…"
    completion = LLM.complete(SYSTEM, prompt(context))
    reply      = Reply.from_json(completion.content)
    message    = reply.message.strip.lines.first?.try(&.strip) || ""
    raise LLM::Failure.new("empty message") if message.empty?
    bump  = Bump.parse?(reply.bump.strip) || raise LLM::Failure.new("unknown bump `#{reply.bump}`")
    stale = context.docs.empty? ? [] of String : reply.docs.map(&.strip).reject(&.empty?)
    Draft.new(message, context.bumpable ? bump : Bump::None, reply.reason.strip, stale, completion.usage)
  rescue ex : LLM::Failure | JSON::ParseException
    note "no proposal from DeepSeek: #{ex.message}"
    nil
  end

  def confirm(context : Context, draft : Draft) : Draft?
    loop do
      show(context, draft)
      case read("accept? [y]es / [e]dit / [n]o: ").try(&.downcase)
      when nil, "n", "no"
        return nil
      when "y", "yes"
        return draft
      when "e", "edit"
        draft = edit(context, draft) || return nil
      end
    end
  end

  private def recent_subjects : Array(String)
    result = git("log", "--no-merges", "--format=%s", "-n", (STYLE_LIMIT * 2).to_s, check: false, capture: true)
    return [] of String unless result.success?
    result.stdout.lines
      .reject { |subject| subject.blank? || STYLE_SKIP.any? { |prefix| subject.starts_with?(prefix) } }
      .first(STYLE_LIMIT)
  end

  private def doc_sources : Array({String, String})
    paths = git_stdout("diff", "--cached", "--name-only").lines
    return [] of {String, String} unless paths.any?(&.starts_with?(SOURCE_PREFIX))
    return [] of {String, String} if paths.any? { |path| DOC_FILES.includes?(path) }
    top = Path[git_stdout("rev-parse", "--show-toplevel")]
    DOC_FILES.compact_map do |name|
      path = top / name
      File.file?(path) ? {name, Diff.clip(File.read(path), DOCS_LIMIT)} : nil
    end
  end

  private def prompt(context : Context) : String
    String.build do |io|
      io << "Write a git commit message for the staged changes below.\n"
      context.version.try { |version| io << "current version: " << version << '\n' }
      io << "allowed bump values: " << context.bumps.join(", ", &.label) << '\n'
      unless context.style.empty?
        io << "\nrecent commit subjects (match their style):\n"
        context.style.each { |subject| io << "- " << subject << '\n' }
      end
      unless context.docs.empty?
        io << "\ndocumentation files (report stale statements in \"docs\"):\n"
        context.docs.each { |name, text| io << "=== " << name << '\n' << text << '\n' }
      end
      io << "\ndiff stat:\n" << context.stat << "\n\ndiff:\n" << context.patch << '\n'
    end
  end

  private def show(context : Context, draft : Draft)
    puts Theme.heading("proposal (#{LLM.label(draft.usage)}):")
    puts "  #{Theme.heading("message:")} #{draft.message}"
    if context.bumpable && (version = context.version)
      if target = context.target(draft.bump)
        puts "  #{Theme.heading("version:")} #{version} → #{Theme.accent(target)} (#{draft.bump.label})"
      else
        puts "  #{Theme.heading("version:")} #{version} unchanged"
      end
      puts "  #{Theme.heading("reason:")} #{draft.reason}" unless draft.reason.empty?
    end
    unless draft.stale.empty?
      puts "  #{Theme.warn("docs may need updating:")}"
      draft.stale.each { |item| puts "    - #{item}" }
    end
    note "message is #{draft.message.size} characters (over #{MESSAGE_LIMIT})" if draft.message.size > MESSAGE_LIMIT
  end

  private def read(question : String) : String?
    print Theme.heading(question)
    STDOUT.flush
    STDIN.gets.try(&.strip)
  end

  private def edit(context : Context, draft : Draft) : Draft?
    typed   = read("message [enter keeps the proposal]: ") || return nil
    message = typed.empty? ? draft.message : typed
    bump    = draft.bump
    if context.bumpable
      listed = context.bumps.join("/", &.label)
      loop do
        answer = read("bump #{listed} [enter keeps #{bump.label}]: ") || return nil
        break if answer.empty?
        if chosen = Bump.parse?(answer)
          bump = chosen
          break
        end
        note "choose one of #{listed}"
      end
    end
    draft.copy_with(message: message, bump: bump)
  end
end
