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

  SYSTEM = <<-PROMPT
  You write git commit messages and judge semantic version bumps.
  Reply with a single json object in exactly this shape:
  {"message": "add a dry-run flag to release", "bump": "patch", "reason": "one short sentence"}
  message: one line, at most #{MESSAGE_LIMIT} characters, imperative mood, lower-case first letter, no trailing period; say what changed and why, not which files.
  bump: one of the allowed values listed by the user, following Semantic Versioning 2.0.0. While the major version is 0, breaking changes are "minor" and everything else is "patch". Choose the smallest allowed value that fits.
  reason: why that bump fits, in one short sentence.
  PROMPT

  record Context, stat : String, patch : String, version : SemanticVersion?, bumpable : Bool do
    def bumps : Array(Bump)
      bumpable ? Bump.values : [Bump::None]
    end

    def target(bump : Bump) : String?
      return nil if bump.none? || !bumpable
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

  def staged(version : String?, bumpable : Bool) : Context
    semver = version.try { |raw| SemanticVersion.parse?(raw) }
    if version && semver.nil?
      note "`#{version}` in shard.yml is not a semantic version; proposing a message only"
      bumpable = false
    end
    stat  = capture(["diff", "--cached", "--stat", "--no-color"])
    patch = capture(["diff", "--cached", "--no-color", "--no-ext-diff", "--", ":/"] + EXCLUDES)
    Context.new(stat, clip(patch), semver, bumpable)
  end

  def request(context : Context) : Draft?
    info "asking DeepSeek (`#{LLM.model}`) for a proposal…"
    reply   = Reply.from_json(LLM.complete(SYSTEM, prompt(context)))
    message = reply.message.strip.lines.first?.try(&.strip) || ""
    raise LLM::Failure.new("empty message") if message.empty?
    bump = Bump.parse?(reply.bump.strip) || raise LLM::Failure.new("unknown bump `#{reply.bump}`")
    Draft.new(message, context.bumpable ? bump : Bump::None, reply.reason.strip)
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
      io << "Write a git commit message for the staged changes below.\n"
      context.version.try { |version| io << "current version: " << version << '\n' }
      io << "allowed bump values: " << context.bumps.join(", ", &.label) << '\n'
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
    puts Theme.heading("proposal (#{LLM.model}):")
    puts "  #{Theme.heading("message:")} #{draft.message}"
    if context.bumpable && (version = context.version)
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
    Draft.new(message, bump, draft.reason)
  end
end
