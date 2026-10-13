# src/dev/graph.cr
require "./theme"

module Dev::Graph
  extend self

  SEP    = '\u001F'
  FORMAT = "#{SEP}%h#{SEP}%s"

  MIN_TEXT = 20

  record Row, graph : String, hash : String, subject : String
  record Cell, graph : String, hash : String, pad : String, text : String

  N_ARM = 1
  S_ARM = 2
  E_ARM = 4
  W_ARM = 8

  BOX = StaticArray[
    ' ', '╵', '╷', '│',
    '╴', '╰', '╭', '├',
    '╶', '╯', '╮', '┤',
    '─', '┴', '┬', '┼',
  ]

  ARC_NE = 1
  ARC_NW = 2
  ARC_SE = 4
  ARC_SW = 8

  BRANCH_NODE = StaticArray[
    '\u{F5EE}', '\u{F5F8}', '\u{F5F6}', '\u{F5FA}',
    '\u{F5F0}', '\u{F600}', '\u{F5FC}', '\u{F604}',
    '\u{F5F2}', '\u{F602}', '\u{F5FE}', '\u{F606}',
    '\u{F5F4}', '\u{F60A}', '\u{F608}', '\u{F60C}',
  ]

  def render(lines : Array(String), width : Int32? = nil) : String
    rows = split_rows(lines)
    if branch_glyphs?
      gutter = branch_width(rows)
      render_branch(layout(rows, width, gutter), gutter)
    else
      render_box(layout(rows, width, nil))
    end
  end

  private def split_rows(lines : Array(String)) : Array(Row)
    lines.map do |line|
      parts = line.split(SEP, 3)
      Row.new(parts[0], parts[1]? || "", parts[2]? || "")
    end
  end

  private def layout(rows : Array(Row), width : Int32?, gutter : Int32?) : Array(Cell)
    cells = Array(Cell).new(rows.size)
    rows.each_with_index do |row, i|
      chunks = width ? wrap_row(row, width - (gutter || row.graph.size)) : nil
      lanes  = continuation(row.graph, rows[i + 1]?.try(&.graph)) if chunks
      if chunks.nil? || lanes.nil?
        cells << Cell.new(row.graph, row.hash, "", row.subject)
        next
      end
      pad = " " * (row.hash.size + 1)
      chunks.each_with_index do |chunk, j|
        cells << (j == 0 ? Cell.new(row.graph, row.hash, "", chunk) : Cell.new(lanes, "", pad, chunk))
      end
    end
    cells
  end

  private def wrap_row(row : Row, room : Int32) : Array(String)?
    return nil if row.hash.empty?
    avail = room - row.hash.size - 1
    return nil if avail < MIN_TEXT || row.subject.size <= avail
    wrap_text(row.subject, avail)
  end

  private def wrap_text(text : String, avail : Int32) : Array(String)
    chunks = [] of String
    line   = ""
    text.split(' ', remove_empty: true) do |word|
      unless line.empty?
        if line.size + 1 + word.size <= avail
          line = "#{line} #{word}"
          next
        end
        chunks << line
      end
      while word.size > avail
        chunks << word[0, avail]
        word = word[avail..]
      end
      line = word
    end
    chunks << line unless line.empty?
    chunks
  end

  private def continuation(graph : String, below : String?) : String?
    lanes = Array(Char).new(graph.size, ' ')
    graph.each_char_with_index do |ch, c|
      case ch
      when ' '
      when '|'
        lanes[c] = '|'
      when '*'
        lanes[c] = '|' if below && descends?(below, c)
      when '/', '\\'
        target = ch == '/' ? c - 1 : c + 1
        return nil unless target >= 0 && graph[target]? == ' ' && lanes[target] == ' '
        lanes[target] = '|'
      else
        return nil
      end
    end
    lanes.join
  end

  private def descends?(below : String, c : Int32) : Bool
    down = below[c]?
    down == '|' || down == '*' || down == '/' || down == '\\' ||
      below[c + 1]? == '\\' || (c > 0 && below[c - 1]? == '/')
  end

  private def branch_width(rows : Array(Row)) : Int32
    width = 1
    rows.each do |row|
      graph = row.graph
      width = graph.size if graph.size > width
      graph.each_char_with_index do |ch, c|
        width = c + 2 if (ch == '\\' || ch == '/') && c + 2 > width
      end
    end
    width
  end

  private def branch_glyphs? : Bool
    case ENV["PROJECT_TREE"]?
    when "branch" then return true
    when "box"    then return false
    end
    term_program = ENV["TERM_PROGRAM"]?
    return true if term_program == "ghostty" || term_program == "kitty"
    if term = ENV["TERM"]?
      return true if term.includes?("kitty") || term.includes?("ghostty")
    end
    false
  end

  private def box_cell(grid : Array(Array(Char)), r : Int32, c : Int32) : Char
    ch = grid[r][c]
    at = ->(dr : Int32, dc : Int32) do
      rr = r + dr
      cc = c + dc
      if rr >= 0 && rr < grid.size && cc >= 0 && cc < grid[rr].size
        grid[rr][cc]
      else
        ' '
      end
    end
    case ch
    when '*'  then '●'
    when '\\' then '╲'
    when '/'  then '╱'
    when '|'
      arms = 0
      up   = at.call(-1, 0)
      arms |= N_ARM if up == '|' || up == '*' || at.call(-1, -1) == '\\' || at.call(-1, 1) == '/'
      down = at.call(1, 0)
      arms |= S_ARM if down == '|' || down == '*' || down == '/' || down == '\\' || at.call(1, -1) == '/' || at.call(1, 1) == '\\'
      right = at.call(0, 1)
      arms |= E_ARM if right == '\\' || right == '/'
      left = at.call(0, -1)
      arms |= W_ARM if left == '\\' || left == '/'
      BOX[arms]
    when '-', '_'
      arms = W_ARM | E_ARM
      arms |= S_ARM if at.call(1, 1) == '\\'
      BOX[arms]
    when '.'
      arms = 0
      left = at.call(0, -1)
      arms |= W_ARM if left == '-' || left == '_' || left == '*'
      arms |= S_ARM if at.call(1, 1) == '\\'
      BOX[arms]
    else
      ch
    end
  end

  private def emit_glyph(io : IO, glyph : Char, column : Int32, node : Bool)
    if glyph == ' '
      io << glyph
    elsif node
      io << Theme.node(column, glyph)
    else
      io << Theme.lane(column, glyph)
    end
  end

  private def emit_text(io : IO, cell : Cell)
    io << Theme.sha(cell.hash) << ' ' unless cell.hash.empty?
    io << cell.pad << cell.text
  end

  private def render_box(rows : Array(Cell)) : String
    grid = rows.map(&.graph.chars)
    rendered = rows.map_with_index do |row, r|
      String.build do |io|
        grid[r].each_index { |c| emit_glyph(io, box_cell(grid, r, c), c, grid[r][c] == '*') }
        emit_text(io, row)
      end.rstrip
    end
    rendered.join("\n")
  end

  private def branch_glyph(vline : Bool, hline : Bool, arcs : Int32) : Char?
    return nil if vline && hline
    if vline
      case arcs
      when 0               then '\u{F5D1}'
      when ARC_NE          then '\u{F5DA}'
      when ARC_SE          then '\u{F5DB}'
      when ARC_NW          then '\u{F5DD}'
      when ARC_SW          then '\u{F5DE}'
      when ARC_NW | ARC_NE then '\u{F5E6}'
      when ARC_SW | ARC_SE then '\u{F5E7}'
      when ARC_NW | ARC_SE then '\u{F5EA}'
      when ARC_NE | ARC_SW then '\u{F5EB}'
      end
    elsif hline
      case arcs
      when 0               then '\u{F5D0}'
      when ARC_SW          then '\u{F5E0}'
      when ARC_SE          then '\u{F5E1}'
      when ARC_NW          then '\u{F5E3}'
      when ARC_NE          then '\u{F5E4}'
      when ARC_SW | ARC_NW then '\u{F5E8}'
      when ARC_NE | ARC_SE then '\u{F5E9}'
      when ARC_NW | ARC_SE then '\u{F5EC}'
      when ARC_NE | ARC_SW then '\u{F5ED}'
      end
    else
      case arcs
      when 0               then ' '
      when ARC_SE          then '\u{F5D6}'
      when ARC_SW          then '\u{F5D7}'
      when ARC_NE          then '\u{F5D8}'
      when ARC_NW          then '\u{F5D9}'
      when ARC_NE | ARC_SE then '\u{F5DC}'
      when ARC_NW | ARC_SW then '\u{F5DF}'
      when ARC_SE | ARC_SW then '\u{F5E2}'
      when ARC_NE | ARC_NW then '\u{F5E5}'
      when ARC_NW | ARC_SE then '\u{F5EA}'
      when ARC_NE | ARC_SW then '\u{F5EB}'
      end
    end
  end

  private def branch_cell(node : Bool, arms : Int32, vline : Bool, hline : Bool,
                          arcs : Int32, last_row : Bool, orig : Char) : Char
    return BRANCH_NODE[arms] if node
    unless vline || hline || arcs != 0
      return orig
    end
    return '\u{F5D4}' if last_row && vline && !hline && arcs == 0
    if glyph = branch_glyph(vline, hline, arcs)
      return glyph
    end
    mask = 0
    mask |= N_ARM if vline || (arcs & (ARC_NE | ARC_NW)) != 0
    mask |= S_ARM if vline || (arcs & (ARC_SE | ARC_SW)) != 0
    mask |= E_ARM if hline || (arcs & (ARC_NE | ARC_SE)) != 0
    mask |= W_ARM if hline || (arcs & (ARC_NW | ARC_SW)) != 0
    BOX[mask]
  end

  private def render_branch(rows : Array(Cell), width : Int32) : String
    return "" if rows.empty?
    n = rows.size
    grid = rows.map do |row|
      chars = row.graph.chars
      chars.size < width ? chars + [' '] * (width - chars.size) : chars
    end
    node  = Array.new(n) { Array.new(width, false) }
    arms  = Array.new(n) { Array.new(width, 0) }
    arcs  = Array.new(n) { Array.new(width, 0) }
    vline = Array.new(n) { Array.new(width, false) }
    hline = Array.new(n) { Array.new(width, false) }
    n.times do |r|
      width.times do |c|
        case grid[r][c]
        when '*'
          node[r][c] = true
        when '|'
          vline[r][c] = true
        when '-', '_'
          hline[r][c] = true
          if r + 1 < n
            arcs[r][c] |= ARC_SE if c + 1 < width && grid[r + 1][c + 1] == '\\'
            arcs[r][c] |= ARC_SW if c > 0 && grid[r + 1][c - 1] == '/'
          end
        when '.'
          arcs[r][c] |= ARC_SW
        when '\\'
          extra_n = r > 0 && (grid[r - 1][c] == '|' || grid[r - 1][c] == '*')
          if r + 1 < n && c + 1 < width && grid[r + 1][c + 1] == '\\'
            arcs[r][c] |= ARC_SW
            arcs[r][c] |= ARC_NW if extra_n
          else
            hline[r][c] = true
            arcs[r][c] |= ARC_NW if extra_n
            if grid[r][c + 1] == '*'
              arms[r][c + 1] |= W_ARM
            else
              arcs[r][c + 1] |= ARC_SW
            end
          end
          if grid[r][c - 1] == '*'
            arms[r][c - 1] |= E_ARM
          else
            arcs[r][c - 1] |= ARC_NE
          end
        when '/'
          extra_n = r > 0 && (grid[r - 1][c] == '|' || grid[r - 1][c] == '*')
          if r + 1 < n && c > 0 && grid[r + 1][c - 1] == '/'
            arcs[r][c] |= ARC_SE
            arcs[r][c] |= ARC_NE if extra_n
          else
            hline[r][c] = true
            arcs[r][c] |= ARC_NW if extra_n
            if grid[r][c - 1] == '*'
              arms[r][c - 1] |= E_ARM
            else
              arcs[r][c - 1] |= ARC_SE
            end
          end
          if grid[r][c + 1] == '*'
            arms[r][c + 1] |= W_ARM
          else
            arcs[r][c + 1] |= ARC_NW
          end
        end
      end
    end
    n.times do |r|
      width.times do |c|
        next unless node[r][c]
        if r > 0 && (grid[r - 1][c] == '|' || grid[r - 1][c] == '*' ||
           (c > 0 && grid[r - 1][c - 1] == '\\') ||
           (c + 1 < width && grid[r - 1][c + 1] == '/'))
          arms[r][c] |= N_ARM
        end
        if r + 1 < n && (grid[r + 1][c] == '|' || grid[r + 1][c] == '*' ||
           grid[r + 1][c] == '/' || grid[r + 1][c] == '\\' ||
           (c + 1 < width && grid[r + 1][c + 1] == '\\') ||
           (c > 0 && grid[r + 1][c - 1] == '/'))
          arms[r][c] |= S_ARM
        end
        arms[r][c] |= E_ARM if c + 1 < width && (grid[r][c + 1] == '-' || grid[r][c + 1] == '_')
        arms[r][c] |= W_ARM if c > 0 && (grid[r][c - 1] == '-' || grid[r][c - 1] == '_')
      end
    end
    last = n - 1
    rendered = rows.map_with_index do |row, r|
      String.build do |io|
        width.times do |c|
          glyph = branch_cell(node[r][c], arms[r][c], vline[r][c], hline[r][c],
            arcs[r][c], r == last, grid[r][c])
          emit_glyph(io, glyph, c, node[r][c])
        end
        emit_text(io, row)
      end.rstrip
    end
    rendered.join("\n")
  end
end
