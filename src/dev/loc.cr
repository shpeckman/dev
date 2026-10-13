# src/dev/loc.cr
require "./cli"

module Dev::Loc
  extend self
  include CLI

  record Lang, name : String, line_comment : String? = nil,
    block_open : String? = nil, block_close : String? = nil

  LANGS = {
    ".cr"      => Lang.new("Crystal", "#"),
    ".rb"      => Lang.new("Ruby", "#"),
    ".py"      => Lang.new("Python", "#"),
    ".sh"      => Lang.new("Shell", "#"),
    ".bash"    => Lang.new("Shell", "#"),
    ".zsh"     => Lang.new("Shell", "#"),
    ".yml"     => Lang.new("YAML", "#"),
    ".yaml"    => Lang.new("YAML", "#"),
    ".toml"    => Lang.new("TOML", "#"),
    ".c"       => Lang.new("C", "//", "/*", "*/"),
    ".h"       => Lang.new("C/C++", "//", "/*", "*/"),
    ".cpp"     => Lang.new("C++", "//", "/*", "*/"),
    ".hpp"     => Lang.new("C++", "//", "/*", "*/"),
    ".cc"      => Lang.new("C++", "//", "/*", "*/"),
    ".java"    => Lang.new("Java", "//", "/*", "*/"),
    ".js"      => Lang.new("JavaScript", "//", "/*", "*/"),
    ".jsx"     => Lang.new("JavaScript", "//", "/*", "*/"),
    ".ts"      => Lang.new("TypeScript", "//", "/*", "*/"),
    ".tsx"     => Lang.new("TypeScript", "//", "/*", "*/"),
    ".go"      => Lang.new("Go", "//", "/*", "*/"),
    ".rs"      => Lang.new("Rust", "//", "/*", "*/"),
    ".swift"   => Lang.new("Swift", "//", "/*", "*/"),
    ".kt"      => Lang.new("Kotlin", "//", "/*", "*/"),
    ".kts"     => Lang.new("Kotlin", "//", "/*", "*/"),
    ".cs"      => Lang.new("C#", "//", "/*", "*/"),
    ".sql"     => Lang.new("SQL", "--"),
    ".html"    => Lang.new("HTML", nil, "<!--", "-->"),
    ".xml"     => Lang.new("XML", nil, "<!--", "-->"),
    ".md"      => Lang.new("Markdown", nil, "<!--", "-->"),
    ".json"    => Lang.new("JSON"),
    "Makefile" => Lang.new("Makefile", "#"),
    "makefile" => Lang.new("Makefile", "#"),
  }

  record Tally, lines : Int64, blank : Int64, comment : Int64, code : Int64

  class Count
    property files : Int32
    property lines : Int64
    property blank : Int64
    property comment : Int64
    property code : Int64

    def initialize
      @files = 0
      @lines = 0_i64
      @blank = 0_i64
      @comment = 0_i64
      @code = 0_i64
    end

    def add(t : Tally)
      @files += 1
      @lines += t.lines
      @blank += t.blank
      @comment += t.comment
      @code += t.code
    end
  end

  COMMAND = cmd("loc", "[<targets>...]",
    "count lines of code by language",
    arity: 0..Int32::MAX) do |args|
    targets = args.positional.empty? ? ["."] : args.positional
    -> { cmd_count(targets) }
  end

  def is_hidden?(name : String) : Bool
    name.starts_with?('.') && name != "." && name != ".."
  end

  def text_file?(path : String) : Bool
    File.open(path, "r") do |file|
      buffer = uninitialized UInt8[1024]
      read_bytes = file.read(buffer.to_slice)
      return true if read_bytes == 0
      read_bytes.times do |i|
        return false if buffer[i] == 0
      end
    end
    true
  rescue
    false
  end

  def collect_files(path : String, files : Array(String))
    if File.file?(path)
      files << path if text_file?(path)
    elsif Dir.exists?(path)
      Dir.each_child(path) do |child|
        next if is_hidden?(child)
        collect_files(File.join(path, child), files)
      end
    else
      note "target not found or inaccessible: #{path}"
    end
  end

  def lang_for(path : String) : Lang?
    LANGS[File.basename(path)]? || LANGS[File.extname(path)]?
  end

  def count_file(path : String, lang : Lang?) : Tally?
    lines = blank = comment = code = 0_i64
    in_block = false
    File.each_line(path) do |line|
      lines += 1
      stripped = line.strip
      if stripped.empty?
        blank += 1
        next
      end
      if lang.nil?
        code += 1
        next
      end
      line_comment = lang.line_comment
      block_open   = lang.block_open
      block_close  = lang.block_close
      if in_block
        comment += 1
        in_block = false if block_close && stripped.includes?(block_close)
      elsif line_comment && stripped.starts_with?(line_comment)
        comment += 1
      elsif block_open && stripped.includes?(block_open)
        comment += 1
        in_block = true unless block_close && stripped.includes?(block_close)
      else
        code += 1
      end
    end
    Tally.new(lines, blank, comment, code)
  rescue
    nil
  end

  def format_number(num : Int) : String
    num.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
  end

  def cmd_count(targets : Array(String)) : Int32
    files = [] of String
    targets.each { |t| collect_files(t, files) }

    if files.empty?
      info "no text files found in targets"
      return 0
    end

    stats = {} of String => Count
    files.each do |file|
      lang = lang_for(file)
      tally = count_file(file, lang)
      next unless tally
      key = lang ? lang.name : "other"
      (stats[key] ||= Count.new).add(tally)
    end

    entries = stats.to_a.sort_by { |name, c| {-c.code, name} }
    totals  = Count.new
    entries.each do |_, c|
      totals.files += c.files
      totals.lines += c.lines
      totals.blank += c.blank
      totals.comment += c.comment
      totals.code += c.code
    end

    headers = ["Language", "Files", "Lines", "Blank", "Comment", "Code"]
    data = entries.map do |name, c|
      [name, format_number(c.files), format_number(c.lines),
       format_number(c.blank), format_number(c.comment), format_number(c.code)]
    end
    data << ["Total", format_number(totals.files), format_number(totals.lines),
             format_number(totals.blank), format_number(totals.comment), format_number(totals.code)]

    widths = headers.map(&.size)
    data.each do |row|
      row.each_with_index { |cell, i| widths[i] = cell.size if cell.size > widths[i] }
    end

    puts headers.map_with_index { |h, i|
      Theme.heading(i == 0 ? h.ljust(widths[i]) : h.rjust(widths[i]))
    }.join("  ")

    data.each_with_index do |row, idx|
      name = row[0].ljust(widths[0])
      nums = (1..5).map { |i| row[i].rjust(widths[i]) }
      puts(idx == data.size - 1 ?
        Theme.ok("#{name}  #{nums.join("  ")}") :
        "#{Theme.accent(name)}  #{nums.join("  ")}")
    end
    0
  end
end
