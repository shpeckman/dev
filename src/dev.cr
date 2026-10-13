# src/dev.cr
require "./dev/theme"
require "./dev/terminal"
require "./dev/graph"
require "./dev/cli"
require "./dev/git"
require "./dev/llm"
require "./dev/proposal"
require "./dev/project"
require "./dev/tok"
require "./dev/loc"
require "./dev/chlog"

module Dev
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end
