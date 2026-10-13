# src/dev/theme.cr
require "colorize"

module Dev::Theme
  extend self

  record Style, fore : Colorize::ColorANSI, mode : Colorize::Mode = Colorize::Mode::None

  STYLES = {
    error:   Style.new(:red, :bold),
    warn:    Style.new(:yellow),
    ok:      Style.new(:green),
    heading: Style.new(:default, :bold),
    command: Style.new(:cyan),
    accent:  Style.new(:cyan, :bold),
    muted:   Style.new(:dark_gray),
    sha:     Style.new(:yellow),
  }

  LANES = StaticArray[
    Colorize::ColorANSI::Cyan,
    Colorize::ColorANSI::Magenta,
    Colorize::ColorANSI::Green,
    Colorize::ColorANSI::Yellow,
    Colorize::ColorANSI::Blue,
    Colorize::ColorANSI::Red,
  ]

  {% for role in STYLES.keys %}
    def {{ role.id }}(text)
      paint(text, STYLES[{{ role.symbolize }}])
    end
  {% end %}

  def paint(text, style : Style)
    text.colorize(style.fore).mode(style.mode)
  end

  def lane(column : Int32, glyph : Char)
    glyph.colorize(LANES[(column // 2) % LANES.size])
  end

  def node(column : Int32, glyph : Char)
    lane(column, glyph).bold
  end

  def markup(text : String, role : Symbol? = nil) : String
    return text unless Colorize.enabled?
    base = role ? STYLES[role] : nil
    String.build do |io|
      text.split('`').each_with_index do |part, i|
        if i.odd?
          io << paint(part, STYLES[:accent])
        elsif base
          io << paint(part, base)
        else
          io << part
        end
      end
    end
  end
end
