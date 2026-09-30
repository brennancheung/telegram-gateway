import Foundation

/// A QR code symbol: a square grid of dark/light modules. Encodes arbitrary bytes in byte mode,
/// versions 1–40 (21×21 to 177×177 modules), with automatic version and mask selection.
/// Follows ISO/IEC 18004; the structure mirrors Nayuki's reference encoder.
public struct QRCode: Sendable, Equatable {
    /// Error correction level: how much of the symbol may be damaged and still decode.
    public enum ErrorCorrection: Int, Sendable, CaseIterable {
        case low = 0, medium = 1, quartile = 2, high = 3

        /// The two-bit value written into the format information.
        var formatBits: Int {
            switch self {
            case .low: 1
            case .medium: 0
            case .quartile: 3
            case .high: 2
            }
        }
    }

    public enum EncodingError: Error, Equatable {
        /// The data does not fit in version 40 at the requested error correction level.
        case tooLong
    }

    /// 1…40.
    public let version: Int
    /// Modules per side: `version * 4 + 17`.
    public let size: Int
    public let errorCorrection: ErrorCorrection
    /// The mask pattern chosen (0…7).
    public let mask: Int
    /// `modules[y][x]` is true for a dark module.
    public let modules: [[Bool]]

    public func isDark(x: Int, y: Int) -> Bool {
        guard (0..<size).contains(x), (0..<size).contains(y) else { return false }
        return modules[y][x]
    }

    /// Encodes `text` as UTF-8 in byte mode.
    public static func encode(_ text: String, errorCorrection: ErrorCorrection = .medium) throws -> QRCode {
        try encode(Array(text.utf8), errorCorrection: errorCorrection)
    }

    /// Encodes raw bytes in byte mode, choosing the smallest version that fits.
    public static func encode(_ bytes: [UInt8], errorCorrection: ErrorCorrection = .medium) throws -> QRCode {
        // Smallest version whose data capacity holds mode (4) + count + payload bits.
        var version = 1
        while true {
            let capacity = numDataCodewords(version: version, ecl: errorCorrection) * 8
            let countBits = version <= 9 ? 8 : 16
            if 4 + countBits + bytes.count * 8 <= capacity { break }
            version += 1
            if version > 40 { throw EncodingError.tooLong }
        }

        // Data bit stream: mode indicator, character count, bytes, terminator, padding.
        var bits = BitBuffer()
        bits.append(0b0100, count: 4)
        bits.append(bytes.count, count: version <= 9 ? 8 : 16)
        for byte in bytes { bits.append(Int(byte), count: 8) }
        let capacity = numDataCodewords(version: version, ecl: errorCorrection) * 8
        bits.append(0, count: min(4, capacity - bits.count))
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacity {
            bits.append(pad, count: 8)
            pad ^= 0xEC ^ 0x11
        }

        return QRCode(version: version, errorCorrection: errorCorrection, data: bits.bytes)
    }

    // MARK: Construction

    private init(version: Int, errorCorrection: ErrorCorrection, data: [UInt8]) {
        let size = version * 4 + 17
        var canvas = Canvas(size: size)
        canvas.drawFunctionPatterns(version: version)
        let codewords = QRCode.addErrorCorrection(data, version: version, ecl: errorCorrection)
        canvas.drawCodewords(codewords)

        // Try every mask, keep the one with the lowest penalty score.
        var bestMask = 0
        var bestPenalty = Int.max
        for mask in 0..<8 {
            canvas.applyMask(mask)
            canvas.drawFormatBits(ecl: errorCorrection, mask: mask)
            let penalty = canvas.penaltyScore()
            if penalty < bestPenalty {
                bestPenalty = penalty
                bestMask = mask
            }
            canvas.applyMask(mask)  // XOR is its own inverse
        }
        canvas.applyMask(bestMask)
        canvas.drawFormatBits(ecl: errorCorrection, mask: bestMask)

        self.version = version
        self.size = size
        self.errorCorrection = errorCorrection
        self.mask = bestMask
        self.modules = canvas.modules
    }

    // MARK: Capacity tables

    /// Number of data modules available (everything that is not a function pattern).
    static func numRawDataModules(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let numAlign = version / 7 + 2
            result -= (25 * numAlign - 10) * numAlign - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    static func numDataCodewords(version: Int, ecl: ErrorCorrection) -> Int {
        numRawDataModules(version: version) / 8
            - eccCodewordsPerBlock[ecl.rawValue][version] * numErrorCorrectionBlocks[ecl.rawValue][version]
    }

    // Indexed [ecl][version]; index 0 is unused.
    static let eccCodewordsPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]

    static let numErrorCorrectionBlocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    // MARK: Error correction

    /// Splits the data into blocks, appends Reed-Solomon codewords to each, and interleaves.
    static func addErrorCorrection(_ data: [UInt8], version: Int, ecl: ErrorCorrection) -> [UInt8] {
        let numBlocks = numErrorCorrectionBlocks[ecl.rawValue][version]
        let blockEccLen = eccCodewordsPerBlock[ecl.rawValue][version]
        let rawCodewords = numRawDataModules(version: version) / 8
        let numShortBlocks = numBlocks - rawCodewords % numBlocks
        let shortBlockLen = rawCodewords / numBlocks

        let divisor = ReedSolomon.divisor(degree: blockEccLen)
        var blocks: [[UInt8]] = []
        var offset = 0
        for i in 0..<numBlocks {
            let dataLen = shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1)
            let block = Array(data[offset..<offset + dataLen])
            offset += dataLen
            let ecc = ReedSolomon.remainder(block, divisor: divisor)
            // Short blocks get a placeholder so every block has the same length for interleaving.
            blocks.append(block + (i < numShortBlocks ? [0] : []) + ecc)
        }

        var result: [UInt8] = []
        for i in 0..<blocks[0].count {
            for j in 0..<numBlocks where !(i == shortBlockLen - blockEccLen && j < numShortBlocks) {
                result.append(blocks[j][i])
            }
        }
        return result
    }

    enum ReedSolomon {
        /// Generator polynomial coefficients for `degree` error correction codewords.
        static func divisor(degree: Int) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: degree)
            result[degree - 1] = 1
            var root: UInt8 = 1
            for _ in 0..<degree {
                for j in 0..<degree {
                    result[j] = multiply(result[j], root)
                    if j + 1 < degree { result[j] ^= result[j + 1] }
                }
                root = multiply(root, 0x02)
            }
            return result
        }

        static func remainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: divisor.count)
            for byte in data {
                let factor = byte ^ result.removeFirst()
                result.append(0)
                for i in 0..<divisor.count {
                    result[i] ^= multiply(divisor[i], factor)
                }
            }
            return result
        }

        /// Multiplication in GF(2^8) with the QR polynomial x^8 + x^4 + x^3 + x^2 + 1.
        static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
            var z = 0
            var i = 7
            while i >= 0 {
                z = (z << 1) ^ ((z >> 7) * 0x11D)
                z ^= ((Int(y) >> i) & 1) * Int(x)
                i -= 1
            }
            return UInt8(z & 0xFF)
        }
    }

    // MARK: Bit buffer

    struct BitBuffer {
        private(set) var bits: [Bool] = []

        var count: Int { bits.count }

        mutating func append(_ value: Int, count: Int) {
            guard count > 0 else { return }
            for i in stride(from: count - 1, through: 0, by: -1) {
                bits.append((value >> i) & 1 == 1)
            }
        }

        var bytes: [UInt8] {
            var result = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
            for (i, bit) in bits.enumerated() where bit {
                result[i / 8] |= 1 << (7 - i % 8)
            }
            return result
        }
    }

    // MARK: Canvas: module grid with function-pattern bookkeeping

    struct Canvas {
        let size: Int
        var modules: [[Bool]]
        var isFunction: [[Bool]]

        init(size: Int) {
            self.size = size
            modules = Array(repeating: Array(repeating: false, count: size), count: size)
            isFunction = modules
        }

        mutating func setFunction(x: Int, y: Int, dark: Bool) {
            modules[y][x] = dark
            isFunction[y][x] = true
        }

        mutating func drawFunctionPatterns(version: Int) {
            for i in 0..<size {
                setFunction(x: 6, y: i, dark: i % 2 == 0)
                setFunction(x: i, y: 6, dark: i % 2 == 0)
            }
            drawFinder(x: 3, y: 3)
            drawFinder(x: size - 4, y: 3)
            drawFinder(x: 3, y: size - 4)

            let positions = QRCode.alignmentPositions(version: version)
            for (i, ax) in positions.enumerated() {
                for (j, ay) in positions.enumerated() {
                    let onFinder = (i == 0 && j == 0)
                        || (i == 0 && j == positions.count - 1)
                        || (i == positions.count - 1 && j == 0)
                    if !onFinder { drawAlignment(x: ax, y: ay) }
                }
            }

            drawFormatBits(ecl: .low, mask: 0)  // placeholder, reserves the modules
            drawVersion(version)
        }

        private mutating func drawFinder(x: Int, y: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let dist = max(abs(dx), abs(dy))
                    let px = x + dx, py = y + dy
                    if (0..<size).contains(px), (0..<size).contains(py) {
                        setFunction(x: px, y: py, dark: dist != 2 && dist != 4)
                    }
                }
            }
        }

        private mutating func drawAlignment(x: Int, y: Int) {
            for dy in -2...2 {
                for dx in -2...2 {
                    setFunction(x: x + dx, y: y + dy, dark: max(abs(dx), abs(dy)) != 1)
                }
            }
        }

        mutating func drawFormatBits(ecl: ErrorCorrection, mask: Int) {
            let data = ecl.formatBits << 3 | mask
            var rem = data
            for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
            let bits = (data << 10 | rem) ^ 0x5412
            func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }

            for i in 0...5 { setFunction(x: 8, y: i, dark: bit(i)) }
            setFunction(x: 8, y: 7, dark: bit(6))
            setFunction(x: 8, y: 8, dark: bit(7))
            setFunction(x: 7, y: 8, dark: bit(8))
            for i in 9..<15 { setFunction(x: 14 - i, y: 8, dark: bit(i)) }

            for i in 0..<8 { setFunction(x: size - 1 - i, y: 8, dark: bit(i)) }
            for i in 8..<15 { setFunction(x: 8, y: size - 15 + i, dark: bit(i)) }
            setFunction(x: 8, y: size - 8, dark: true)  // the always-dark module
        }

        private mutating func drawVersion(_ version: Int) {
            guard version >= 7 else { return }
            var rem = version
            for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
            let bits = version << 12 | rem
            for i in 0..<18 {
                let dark = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3
                let b = i / 3
                setFunction(x: a, y: b, dark: dark)
                setFunction(x: b, y: a, dark: dark)
            }
        }

        /// Places codeword bits in the zigzag order the standard defines.
        mutating func drawCodewords(_ data: [UInt8]) {
            var i = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vert in 0..<size {
                    for j in 0..<2 {
                        let x = right - j
                        let upward = ((right + 1) & 2) == 0
                        let y = upward ? size - 1 - vert : vert
                        if !isFunction[y][x], i < data.count * 8 {
                            modules[y][x] = (data[i >> 3] >> (7 - (i & 7))) & 1 == 1
                            i += 1
                        }
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !isFunction[y][x] {
                    let invert: Bool
                    switch mask {
                    case 0: invert = (x + y) % 2 == 0
                    case 1: invert = y % 2 == 0
                    case 2: invert = x % 3 == 0
                    case 3: invert = (x + y) % 3 == 0
                    case 4: invert = (x / 3 + y / 2) % 2 == 0
                    case 5: invert = x * y % 2 + x * y % 3 == 0
                    case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                    default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { modules[y][x].toggle() }
                }
            }
        }

        /// The standard's four penalty rules; lower is easier to scan.
        func penaltyScore() -> Int {
            var result = 0
            // Rule 1: runs of 5+ same-colour modules in a row or column.
            for y in 0..<size {
                var runColor = false, runX = 0
                for x in 0..<size {
                    if modules[y][x] == runColor {
                        runX += 1
                        if runX == 5 { result += 3 } else if runX > 5 { result += 1 }
                    } else {
                        runColor = modules[y][x]
                        runX = 1
                    }
                }
            }
            for x in 0..<size {
                var runColor = false, runY = 0
                for y in 0..<size {
                    if modules[y][x] == runColor {
                        runY += 1
                        if runY == 5 { result += 3 } else if runY > 5 { result += 1 }
                    } else {
                        runColor = modules[y][x]
                        runY = 1
                    }
                }
            }
            // Rule 2: 2×2 blocks of the same colour.
            for y in 0..<size - 1 {
                for x in 0..<size - 1 {
                    let c = modules[y][x]
                    if c == modules[y][x + 1], c == modules[y + 1][x], c == modules[y + 1][x + 1] {
                        result += 3
                    }
                }
            }
            // Rule 3: finder-like 1:1:3:1:1 patterns with 4 light modules on either side.
            let patternA = [true, false, true, true, true, false, true, false, false, false, false]
            let patternB = Array(patternA.reversed())
            for y in 0..<size {
                for x in 0...(size - 11) {
                    let row = Array(modules[y][x..<x + 11])
                    if row == patternA || row == patternB { result += 40 }
                }
            }
            for x in 0..<size {
                for y in 0...(size - 11) {
                    let col = (y..<y + 11).map { modules[$0][x] }
                    if col == patternA || col == patternB { result += 40 }
                }
            }
            // Rule 4: deviation of the dark proportion from 50%.
            let dark = modules.reduce(0) { sum, row in sum + row.filter { $0 }.count }
            let total = size * size
            let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
            result += k * 10
            return result
        }
    }

    static func alignmentPositions(version: Int) -> [Int] {
        guard version > 1 else { return [] }
        let numAlign = version / 7 + 2
        let size = version * 4 + 17
        let step = version == 32 ? 26 : (version * 4 + numAlign * 2 + 1) / (numAlign * 2 - 2) * 2
        var result = [6]
        var pos = size - 7
        for _ in 0..<(numAlign - 1) {
            result.insert(pos, at: 1)
            pos -= step
        }
        return result
    }
}
