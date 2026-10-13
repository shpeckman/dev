# src/dev/terminal.cr
lib LibTTY
  {% if flag?(:linux) %}
    TIOCGWINSZ = 0x5413_u64
  {% else %}
    TIOCGWINSZ = 0x40087468_u64
  {% end %}

  struct Winsize
    row    : UInt16
    col    : UInt16
    xpixel : UInt16
    ypixel : UInt16
  end

  fun ioctl(fd : Int32, request : UInt64, ...) : Int32
end

module Dev::Terminal
  extend self

  def columns(io : IO::FileDescriptor = STDOUT) : Int32?
    return nil unless io.tty?
    size = LibTTY::Winsize.new
    return nil unless LibTTY.ioctl(io.fd, LibTTY::TIOCGWINSZ, pointerof(size)) == 0
    size.col > 0 ? size.col.to_i32 : nil
  end

  def wrap_width(default : Int32?) : Int32?
    if value = ENV["PROJECT_WIDTH"]?
      cols = value.to_i?
      return nil if cols == 0
      return cols if cols && cols > 0
    end
    columns || default
  end
end
