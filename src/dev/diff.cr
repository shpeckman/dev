# src/dev/diff.cr
require "./git"

module Dev::Diff
  extend self
  include Git

  PATCH_LIMIT = 48_000

  EXCLUDES = [
    ":(exclude)*.lock",
    ":(exclude)*-lock.json",
    ":(exclude)*-lock.yaml",
    ":(exclude)*.min.js",
    ":(exclude)*.min.css",
  ]

  def stat(base : Array(String)) : String
    capture(base + ["--stat", "--no-color"])
  end

  def patch(base : Array(String)) : String
    clip(capture(base + ["--no-color", "--no-ext-diff", "--", ":/"] + EXCLUDES))
  end

  def capture(args : Array(String)) : String
    invoke("git", args, true, true).stdout
  end

  def clip(text : String, limit : Int32 = PATCH_LIMIT) : String
    return text if text.size <= limit
    "#{text[0, limit]}\n[truncated: #{text.size - limit} more characters]"
  end
end
