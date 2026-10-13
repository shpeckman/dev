# src/dev/git.cr
require "./cli"

module Dev::Git
  extend self
  include CLI

  record GitResult, status : Process::Status, stdout : String, stderr : String do
    def success?
      status.success?
    end
  end

  def git(*args : String, check : Bool = true, capture : Bool = false) : GitResult
    if capture
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run("git", args.to_a, output: stdout, error: stderr)
      result = GitResult.new(status, stdout.to_s, stderr.to_s)
      if check && !result.success?
        STDERR.print result.stderr unless result.stderr.empty?
        die "`git #{args.join(" ")}` failed (exit #{status.exit_code})"
      end
      result
    else
      status = Process.run("git", args.to_a,
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      if check && !status.success?
        die "`git #{args.join(" ")}` failed (exit #{status.exit_code})"
      end
      GitResult.new(status, "", "")
    end
  end

  def git_stdout(*args : String) : String
    git(*args, capture: true).stdout.strip
  end

  def gh_available? : Bool
    !Process.find_executable("gh").nil?
  end

  def gh(*args : String, check : Bool = true) : GitResult
    status = Process.run("gh", args.to_a,
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    if check && !status.success?
      die "`gh #{args.join(" ")}` failed (exit #{status.exit_code})"
    end
    GitResult.new(status, "", "")
  end

  def in_repo? : Bool
    git("rev-parse", "--is-inside-work-tree", check: false, capture: true).success?
  end

  def current_branch : String
    git_stdout("branch", "--show-current")
  end

  def has_origin? : Bool
    git("remote", "get-url", "origin", check: false, capture: true).success?
  end

  def local_branch_exists?(name : String) : Bool
    git("show-ref", "--verify", "--quiet", "refs/heads/#{name}", check: false).success?
  end

  def remote_branch_exists?(name : String) : Bool
    git("show-ref", "--verify", "--quiet", "refs/remotes/origin/#{name}", check: false).success?
  end

  def local_branches(prefix : String = "") : Array(String)
    git_stdout("for-each-ref", "--format=%(refname:short)", "refs/heads/#{prefix}").lines
  end

  def main_branch : String
    if override = ENV["PROJECT_MAIN"]?
      return override unless override.empty?
    end
    {"main", "master"}.each do |cand|
      return cand if local_branch_exists?(cand) || remote_branch_exists?(cand)
    end
    die "no `main` or `master` branch found (set $PROJECT_MAIN)"
  end
end
