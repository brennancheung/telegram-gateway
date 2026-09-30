import Foundation

extension QRCode {
    /// Lines of text that draw the symbol in a terminal, with the 4-module quiet zone the
    /// standard requires. Colours are set explicitly (white on black) with ANSI escapes so the
    /// result reads correctly on light and dark terminal themes.
    ///
    /// - `compact`: two module rows per text line using half-block characters (a version-3
    ///   code fits in 19 lines). Otherwise each module is two full-width characters.
    public func terminalLines(compact: Bool = true, quietZone: Int = 4) -> [String] {
        let total = size + quietZone * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            isDark(x: x - quietZone, y: y - quietZone)
        }
        let reset = "\u{1b}[0m"
        var lines: [String] = []
        if compact {
            // Foreground white, background black. "▀" paints the top half in the foreground.
            let prefix = "\u{1b}[97;40m"
            var y = 0
            while y < total {
                var line = prefix
                for x in 0..<total {
                    let top = dark(x, y)
                    let bottom = y + 1 < total ? dark(x, y + 1) : true
                    switch (top, bottom) {
                    case (false, false): line += "█"
                    case (false, true): line += "▀"
                    case (true, false): line += "▄"
                    case (true, true): line += " "
                    }
                }
                lines.append(line + reset)
                y += 2
            }
        } else {
            for y in 0..<total {
                var line = ""
                for x in 0..<total {
                    line += dark(x, y) ? "\u{1b}[40m  " : "\u{1b}[47m  "
                }
                lines.append(line + reset)
            }
        }
        return lines
    }
}
