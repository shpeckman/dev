# src/dev/tok.cr
require "./cli"
require "./terminal"

module Dev::Tok
  extend self
  include CLI

  COMMAND = cmd("tok", "[<targets>...]",
    "estimate token counts for source and text files",
    arity: 0..Int32::MAX) do |args|
    targets = args.positional.empty? ? ["."] : args.positional
    -> { cmd_count(targets) }
  end

  class Node
    property name : String
    property children : Hash(String, Node)
    property tokens : Int64
    property is_dir : Bool

    def initialize(@name, @is_dir)
      @children = {} of String => Node
      @tokens = 0_i64
    end

    def insert(parts : Array(String), file_tokens : Int64)
      @tokens += file_tokens
      if parts.size == 1
        child = @children[parts[0]] ||= Node.new(parts[0], false)
        child.tokens = file_tokens
      else
        child = @children[parts[0]] ||= Node.new(parts[0], true)
        child.insert(parts[1..], file_tokens)
      end
    end
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

  def format_number(num : Int) : String
    num.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
  end

  def max_line_length(node : Node, depth : Int32) : Int32
    if depth == 0
      return node.children.values.max_of? { |c| max_line_length(c, 1) } || 0
    end
    len = (depth - 1) * 2 + 2 + node.name.size + (node.is_dir ? 1 : 0)
    child_max = node.children.values.max_of? { |c| max_line_length(c, depth + 1) } || 0
    [len, child_max].max
  end

  def render_node(node : Node, prefix : String, is_last : Bool, align_col : Int32)
    glyph = is_last ? "╰╴" : "├╴"
    display_name = node.name + (node.is_dir ? "/" : "")
    line_start = "#{prefix}#{glyph}#{display_name}"

    if node.is_dir
      puts Theme.muted(line_start)
    else
      pad_len = align_col - line_start.chars.size
      pad_len = 1 if pad_len < 1
      pad = " " * pad_len
      tokens_str = "#{format_number(node.tokens).rjust(10)} tk"
      puts "#{Theme.muted(line_start)}#{pad}#{Theme.accent(tokens_str)}"
    end

    sorted = node.children.values.sort_by(&.name.downcase)
    new_prefix = prefix + (is_last ? "  " : "│ ")
    sorted.each_with_index do |child, i|
      render_node(child, new_prefix, i == sorted.size - 1, align_col)
    end
  end

  def cmd_count(targets : Array(String)) : Int32
    files = [] of String
    targets.each { |t| collect_files(t, files) }

    if files.empty?
      info "no text files found in targets"
      return 0
    end

    root = Node.new(".", true)

    files.each do |file|
      tokens = File.size(file).to_i64 // 4
      clean_file = file.starts_with?("./") ? file[2..] : file
      parts = clean_file.split(File::SEPARATOR, remove_empty: true)
      root.insert(parts, tokens)
    end

    columns = Dev::Terminal.columns || 80
    max_len = [max_line_length(root, 0) + 4, 20].max
    max_len = [max_len, columns - 30].min

    root_pad = max_len - 1
    root_pad = 1 if root_pad < 1

    total_str = "#{format_number(root.tokens).rjust(10)} tk total"
    puts ".#{" " * root_pad}#{Theme.ok(total_str)}"

    sorted = root.children.values.sort_by(&.name.downcase)
    sorted.each_with_index do |child, i|
      render_node(child, "", i == sorted.size - 1, max_len)
    end

    0
  end
end
