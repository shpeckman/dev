# src/dev/proposal.cr
require "json"
require "semantic_version"
require "./cli"
require "./git"
require "./llm"

module Dev::Proposal
  extend self
  include CLI
  include Git

  PATCH_LIMIT   = 48_000
  MESSAGE_LIMIT = 72

  EXCLUDES = [
    ":(exclude)*.lock",
    ":(exclude)*-lock.json",
    ":(exclude)*-lock.yaml",
    ":(exclude)*.min.js",
    ":(exclude)*.min.css",
  ]

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

  enum Task
    Commit
    Release
  end

  TASKS = {
    Task::Commit  => "a git commit message for the staged changes below",
    Task::Release => "a release title for squash-merging the changes below into the release branch",
  }

  SYSTEM = <<-PROMPT
  You write git commit messages and release titles and judge semantic version bumps.
  Reply with a single json object in exactly this shape:
  {"message": "add a dry-run flag to release", "bump": "patch", "reason": "one short sentence"}
  message: one line, at most #{MESSAGE_LIMIT} characters, imperative mood, lower-case first letter, no trailing period; say what changed and why, not which files.
  bump: one of the allowed values listed by the user, following Semantic Versioning 2.0.0. While the major version is 0, breaking changes are "minor" and everything else is "patch". Choose the smallest allowed value that fits.
  reason: why that bump fits, in one short sentence.
  PROMPT

  record Context, task : Task, stat : String, patch : String, subjects : Array(String),
    version : SemanticVersion?, floor : Bump, ceiling : Bump do
    def bumps : Array(Bump)
      Bump.values.select { |bump| bump >= floor && bump <= ceiling }
    end

    def target(bump : Bump) : String?
      return nil if bump.none?
      version.try { |current| bump.apply(current).to_s }
    end
  end

  record Draft, message : String, bump : Bump, reason : String

  struct Reply
    include JSON::Serializable

    getter message : String
    getter bump : String = "none"
    getter reason : String = ""
  end

  def context(task : Task, diff : Array(String), subjects : Array(String), version : String?,
              floor : Bump, ceiling : Bump) : Context
    semver = version.try { |raw| SemanticVersion.parse?(raw) }
    if version && semver.nil?
      note "`#{version}` in shard.yml is not a semantic version; proposing a message only"
      floor = ceiling = Bump::None
    end
    stat  = capture(["diff", "--stat", "--no-color"] + diff)
    patch = capture(["diff", "--no-color", "--no-ext-diff"] + diff + ["--", ":/"] + EXCLUDES)
    Context.new(task, stat, clip(patch), subjects, semver, floor, ceiling)
  end

  def request(context : Context) : Draft?
    info "asking DeepSeek (`#{LLM.model}`) for a proposal…"
    reply   = Reply.from_json(LLM.complete(SYSTEM, prompt(context)))
    message = reply.message.strip.lines.first?.try(&.strip) || ""
    raise LLM::Failure.new("empty message") if message.empty?
    bump = Bump.parse?(reply.bump.strip) || raise LLM::Failure.new("unknown bump `#{reply.bump}`")
    Draft.new(message, bump.clamp(context.floor, context.ceiling), reply.reason.strip)
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

  private def prompt(context : Context) : String
    String.build do |io|
      io << "Write " << TASKS[context.task] << ".\n"
      context.version.try { |version| io << "current version: " << version << '\n' }
      io << "allowed bump values: " << context.bumps.join(", ", &.label) << '\n'
      unless context.subjects.empty?
        io << "\ncommit subjects included:\n"
        context.subjects.each { |subject| io << "- " << subject << '\n' }
      end
      io << "\ndiff stat:\n" << context.stat << "\n\ndiff:\n" << context.patch << '\n'
    end
  end

  private def capture(args : Array(String)) : String
    invoke("git", args, true, true).stdout
  end

  private def clip(patch : String) : String
    return patch if patch.size <= PATCH_LIMIT
    "#{patch[0, PATCH_LIMIT]}\n[diff truncated: #{patch.size - PATCH_LIMIT} more characters]"
  end

  private def show(context : Context, draft : Draft)
    offered = context.bumps.size > 1
    puts Theme.heading("proposal (#{LLM.model}):")
    puts "  #{Theme.heading("message:")} #{draft.message}"
    if offered && (version = context.version)
      if target = context.target(draft.bump)
        puts "  #{Theme.heading("version:")} #{version} → #{Theme.accent(target)} (#{draft.bump.label})"
      else
        puts "  #{Theme.heading("version:")} #{version} unchanged"
      end
      puts "  #{Theme.heading("reason:")} #{draft.reason}" unless draft.reason.empty?
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
    choices = context.bumps
    if choices.size > 1
      listed = choices.join("/", &.label)
      loop do
        answer = read("bump #{listed} [enter keeps #{bump.label}]: ") || return nil
        break if answer.empty?
        chosen = Bump.parse?(answer)
        if chosen && choices.includes?(chosen)
          bump = chosen
          break
        end
        note "choose one of #{listed}"
      end
    end
    Draft.new(message, bump, draft.reason)
  end
end
