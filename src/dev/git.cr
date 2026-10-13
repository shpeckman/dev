# src/dev/git.cr
require "./cli"

module Dev::Git
  extend self
  include CLI

  TAG_REF = "refs/tags/"
  PEELED  = "^{}"

  record GitResult, status : Process::Status, stdout : String, stderr : String do
    def success?
      status.success?
    end
  end

  def invoke(tool : String, args : Array(String), check : Bool, capture : Bool,
             input : Process::Stdio = Process::Redirect::Close) : GitResult
    result = if capture
               stdout = IO::Memory.new
               stderr = IO::Memory.new
               status = Process.run(tool, args, input: input, output: stdout, error: stderr)
               GitResult.new(status, stdout.to_s, stderr.to_s)
             else
               status = Process.run(tool, args, input: input,
                 output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
               GitResult.new(status, "", "")
             end
    if check && !result.success?
      STDERR.print result.stderr unless result.stderr.empty?
      die "`#{tool} #{args.join(" ")}` failed (exit #{result.status.exit_code})"
    end
    result
  end

  def git(*args : String, check : Bool = true, capture : Bool = false) : GitResult
    invoke("git", args.to_a, check, capture)
  end

  def git_stdout(*args : String) : String
    git(*args, capture: true).stdout.strip
  end

  def gh_available? : Bool
    !Process.find_executable("gh").nil?
  end

  def require_gh
    die "the GitHub CLI (`gh`) is not installed" unless gh_available?
  end

  def gh(*args : String, check : Bool = true, capture : Bool = false) : GitResult
    invoke("gh", args.to_a, check, capture,
      capture ? Process::Redirect::Close : Process::Redirect::Inherit)
  end

  def gh_repo_exists?(slug : String) : Bool
    gh("repo", "view", slug, check: false, capture: true).success?
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

  def local_tags(prefix : String = "") : Array(String)
    git_stdout("for-each-ref", "--format=%(refname:lstrip=2)", "#{TAG_REF}#{prefix}").lines
  end

  def resolve(rev : String) : String?
    result = git("rev-parse", "--verify", "--quiet", rev, check: false, capture: true)
    result.success? ? result.stdout.strip : nil
  end

  def ancestor?(commit : String, of : String) : Bool
    git("merge-base", "--is-ancestor", commit, of, check: false, capture: true).success?
  end

  def remote_tags : Hash(String, String)?
    result = git("ls-remote", "--tags", "origin", check: false, capture: true)
    return nil unless result.success?
    tags = {} of String => String
    result.stdout.each_line do |line|
      sha, _, ref = line.partition('\t')
      next unless ref.starts_with?(TAG_REF)
      name = ref.lchop(TAG_REF)
      if name.ends_with?(PEELED)
        tags[name.rchop(PEELED)] = sha
      else
        tags.put_if_absent(name) { sha }
      end
    end
    tags
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