# src/dev/cli.cr
require "./theme"
require "./terminal"

module Dev::CLI
  extend self

  alias Action = Proc(Int32)
  alias Prepare = Proc(Args, Action)

  class Error < Exception
  end

  record Opt, long : String, short : Char? = nil, value : String? = nil,
    help : String = "", required : Bool = false do
    def brief : String
      placeholder = value
      if letter = short
        placeholder ? "-#{letter} #{placeholder}" : "-#{letter}"
      else
        placeholder ? "--#{long}=#{placeholder}" : "--#{long}"
      end
    end

    def label : String
      placeholder = value
      full        = placeholder ? "--#{long}=#{placeholder}" : "--#{long}"
      short ? "#{brief}, #{full}" : full
    end
  end

  HELP = Opt.new("help", 'h', help: "show this help")

  record Args, values : Hash(String, String), positional : Array(String) do
    def flag?(name : String) : Bool
      values.has_key?(name)
    end

    def [](name : String) : String
      values[name]
    end

    def []?(name : String) : String?
      values[name]?
    end
  end

  record Cmd, name : String, synopsis : String, summary : String, options : Array(Opt),
    arity : Range(Int32, Int32), prepare : Prepare do
    def label : String
      synopsis.empty? ? name : "#{name} #{synopsis}"
    end

    def usage(program : String) : String
      "usage: #{program} #{label}"
    end

    def help(program : String) : String
      listed = options + [HELP]
      width  = listed.max_of(&.label.size)
      w      = Dev::Terminal.wrap_width(80)
      String.build do |io|
        io << Theme.heading("usage:") << ' ' << program << ' ' << label << '\n'
        listed.each { |opt| Dev::CLI.emit_labeled(io, opt.label, opt.help, width, w) }
      end
    end

    def find_long(key : String) : Opt?
      return HELP if key == HELP.long
      options.find { |opt| opt.long == key }
    end

    def find_short(key : Char) : Opt?
      return HELP if key == HELP.short
      options.find { |opt| opt.short == key }
    end

    def parse(argv : Array(String)) : Args
      values     = {} of String => String
      positional = [] of String
      i          = 0
      while i < argv.size
        arg = argv[i]
        i += 1
        if arg == "--"
          positional.concat(argv[i..])
          break
        elsif arg.starts_with?("--")
          key, eq, inline = arg[2..].partition('=')
          opt = find_long(key) || raise Error.new("invalid option: --#{key}")
          if opt.value
            if eq.empty?
              inline = argv[i]? || raise Error.new("missing value for --#{key}")
              i += 1
            end
            values[opt.long] = inline
          else
            raise Error.new("option --#{key} takes no value") unless eq.empty?
            values[opt.long] = ""
          end
        elsif arg.size > 1 && arg.starts_with?('-')
          opt  = find_short(arg[1]) || raise Error.new("invalid option: #{arg}")
          rest = arg[2..]
          if opt.value
            if rest.empty?
              rest = argv[i]? || raise Error.new("missing value for -#{arg[1]}")
              i += 1
            end
            values[opt.long] = rest
          else
            raise Error.new("invalid option: #{arg}") unless rest.empty?
            values[opt.long] = ""
          end
        else
          positional << arg
        end
      end
      Args.new(values, positional)
    end

    def validate(args : Args, program : String)
      raise Error.new(usage(program)) unless arity.includes?(args.positional.size)
      options.each do |opt|
        raise Error.new("#{name} requires #{opt.brief}") if opt.required && !args.flag?(opt.long)
      end
    end
  end

  record App, name : String, about : String, footer : String, commands : Array(Cmd) do
    def usage : String
      width = commands.max_of(&.label.size)
      w     = Dev::Terminal.wrap_width(80)
      String.build do |io|
        io << Theme.heading("usage:") << ' ' << name << " <command> [options]\n\n"
        io << about << "\n\n" << Theme.heading("commands:") << '\n'
        commands.each { |command| Dev::CLI.emit_labeled(io, command.label, command.summary, width, w) }
        io << '\n' << Theme.muted(footer) << '\n'
      end
    end

    def run(argv : Array(String) = ARGV) : Int32
      Signal::PIPE.reset
      requested = argv[0]?
      case requested
      when nil
        STDERR.print usage
        return 2
      when "-h", "--help", "help"
        print usage
        return 0
      end
      command = commands.find { |cand| cand.name == requested }
      unless command
        STDERR.puts "#{Theme.error("#{name}: error:")} #{Theme.markup("unknown command `#{requested}`")}"
        STDERR.print usage
        return 2
      end
      args = command.parse(argv[1..])
      if args.flag?(HELP.long)
        print command.help(name)
        return 0
      end
      command.validate(args, name)
      action = command.prepare.call(args)
      action.call
    rescue ex : Error
      STDERR.puts "#{Theme.error("#{name}: error:")} #{Theme.markup(ex.message || "")}"
      1
    end
  end

  def cmd(name : String, synopsis : String, summary : String, options : Array(Opt) = [] of Opt,
          arity : Range(Int32, Int32) = 0..0, &prepare : Args -> Action) : Cmd
    Cmd.new(name, synopsis, summary, options, arity, prepare)
  end

  def die(msg : String) : NoReturn
    raise Error.new(msg)
  end

  def info(msg : String)
    puts Theme.markup(msg)
  end

  def ok(msg : String)
    puts Theme.markup(msg, :ok)
  end

  def note(msg : String)
    puts Theme.markup("note: #{msg}", :warn)
  end

  def wrap_text(text : String, width : Int32) : Array(String)
    out = [] of String
    text.each_line do |line|
      if line.size <= width
        out << line
        next
      end
      buf = ""
      line.split(' ', remove_empty: true).each do |word|
        if buf.empty?
          buf = word
        elsif buf.size + 1 + word.size <= width
          buf = "#{buf} #{word}"
        else
          out << buf
          buf = word
        end
        while buf.size > width
          out << buf[0, width]
          buf = buf[width..]
        end
      end
      out << buf unless buf.empty?
    end
    out
  end

  def emit_labeled(io : IO, label : String, text : String, width : Int32, wrap_width : Int32?)
    indent = 2 + width + 2
    lines  = wrap_width && wrap_width > indent ? wrap_text(text, wrap_width - indent) : text.lines
    lines.each_with_index do |line, i|
      if i == 0
        io << "  " << Theme.command(label.ljust(width)) << "  " << line << '\n'
      else
        io << (" " * indent) << line << '\n'
      end
    end
  end
end
