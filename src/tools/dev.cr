# src/tools/dev.cr
require "../dev"

module DevTool
  extend self
  include Dev::CLI

  Theme = Dev::Theme

  ABOUT = <<-ABOUT
  one tool for the dev workflow: a two-branch git
  workflow (init/clone/open/save/undo/release/status/
  backup/remote), DeepSeek-backed history insight
  (find/explain/notes), plus token, line, and
  changelog analysis (tok/loc/chlog)
  ABOUT

  FOOTER = <<-FOOTER
  overrides: $PROJECT_MAIN (default: detected main/master),
             $PROJECT_DEV (default: dev), $PROJECT_BACKUP_DIR,
             $PROJECT_REMOTE (owner/name; default: directory name),
             $PROJECT_PUBLIC=1 (create new remotes public),
             $PROJECT_WIDTH (0 disables graph/help wrapping),
             $PROJECT_TREE=branch|box (force graph glyphs)
  deepseek:  $DEEPSEEK_API_KEY enables find, explain, notes,
             tok --exact, and save proposals without -m
             (terminal only), $PROJECT_LLM_MODEL (default:
             deepseek-flash)
  FOOTER

  APP = App.new("dev", ABOUT, FOOTER,
    Dev::Project::COMMANDS + Dev::Insight::COMMANDS +
    [Dev::Tok::COMMAND, Dev::Loc::COMMAND, Dev::Chlog::COMMAND])

  def main(argv = ARGV) : Int32
    if requested = argv[0]?
      if Dev::Project::REMOVED.includes?(requested)
        STDERR.puts "#{Theme.error("dev: error:")} " \
                    "#{Theme.markup("removed: the workflow is now just `main` (releases) and `#{Dev::Project.dev_branch}` (work) — run `dev open`")}"
        return 1
      end
    end
    APP.run(argv)
  end
end

exit DevTool.main