# src/dev/chlog.cr
require "./cli"
require "./git"

module Dev::Chlog
  extend self
  include CLI
  include Git

  SEP    = '\u001F'
  FORMAT = "%ad#{SEP}%s"

  COMMAND = cmd("chlog", "[<branch>] [-n LIMIT]",
    "generate a changelog from main's release history",
    options: [Opt.new("limit", 'n', "LIMIT", "number of releases (default: all)")],
    arity: 0..1) do |args|
    die "not inside a git repository" unless in_repo?
    branch = args.positional[0]? || main_branch
    raw = args["limit"]?
    limit = raw ? (raw.to_i? || die "invalid LIMIT: #{raw}") : nil
    -> { cmd_changelog(branch, limit) }
  end

  def cmd_changelog(branch : String, limit : Int32?) : Int32
    die "branch `#{branch}` not found" unless local_branch_exists?(branch)
    format = "--format=#{FORMAT}"
    lines = if limit
             git_stdout("log", format, "--date=short", "-n", limit.to_s, branch).lines
           else
             git_stdout("log", format, "--date=short", branch).lines
           end
    if lines.empty?
      info "no commits on `#{branch}`"
      return 0
    end
    lines.each do |line|
      parts = line.split(SEP, 2)
      puts "#{Theme.muted(parts[0])}  #{parts[1]? || ""}"
    end
    0
  end
end
