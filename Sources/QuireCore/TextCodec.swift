import Foundation

public enum LineEnding: String, CaseIterable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"

    public var displayName: String {
        switch self {
        case .lf: return "Unix (LF)"
        case .crlf: return "Windows (CRLF)"
        case .cr: return "Classic Mac (CR)"
        }
    }

    /// Detects the dominant line ending; files with no line breaks default to LF.
    public static func detect(_ s: String) -> LineEnding {
        let ns = s as NSString
        if ns.range(of: "\r\n").location != NSNotFound { return .crlf }
        if ns.range(of: "\r").location != NSNotFound { return .cr }
        return .lf
    }
}

public struct DecodedText {
    public var text: String
    public var encoding: String.Encoding
    public var lineEnding: LineEnding
    public var hasBOM: Bool
}

public struct EncodingError: LocalizedError {
    public let encoding: String.Encoding
    public var errorDescription: String? {
        "The document contains characters that can’t be saved as \(TextCodec.name(of: encoding)). Choose a different encoding (e.g. UTF-8) from the status bar."
    }
}

/// Reads and writes text files. Text is held internally with LF line endings
/// and converted back to the document's own line ending on save.
public enum TextCodec {
    public static let supportedEncodings: [String.Encoding] = [
        .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
        .isoLatin1, .windowsCP1252, .macOSRoman, .ascii, .shiftJIS, .japaneseEUC,
    ]

    public static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .isoLatin1: return "ISO Latin 1"
        case .windowsCP1252: return "Windows Latin 1"
        case .macOSRoman: return "Mac Roman"
        case .ascii: return "ASCII"
        case .shiftJIS: return "Shift JIS"
        case .japaneseEUC: return "EUC-JP"
        default: return String.localizedName(of: encoding)
        }
    }

    public static func normalizeLineEndings(_ s: String) -> String {
        let ns = s as NSString
        guard ns.range(of: "\r").location != NSNotFound else { return s }
        return ns.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func decode(_ data: Data) -> DecodedText {
        let bytes = [UInt8](data.prefix(3))
        var encoding: String.Encoding
        var bom = false
        var text: String?

        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            encoding = .utf8; bom = true
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            encoding = .utf16; bom = true
            text = String(data: data, encoding: .utf16)
        } else {
            encoding = .utf8
            text = String(data: data, encoding: .utf8)
        }
        if text == nil {
            for candidate: String.Encoding in [.windowsCP1252, .macOSRoman, .isoLatin1] {
                if let t = String(data: data, encoding: candidate) {
                    text = t; encoding = candidate; bom = false
                    break
                }
            }
        }
        let raw = text ?? ""
        return DecodedText(text: normalizeLineEndings(raw), encoding: encoding,
                           lineEnding: LineEnding.detect(raw), hasBOM: bom)
    }

    public static func encode(_ text: String, encoding: String.Encoding, lineEnding: LineEnding, bom: Bool) throws -> Data {
        var s = normalizeLineEndings(text)
        if lineEnding != .lf {
            s = (s as NSString).replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        }
        guard var data = s.data(using: encoding, allowLossyConversion: false) else {
            throw EncodingError(encoding: encoding)
        }
        if bom && encoding == .utf8 {
            data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
        }
        return data
    }

    /// Heuristic used by multi-file search to skip binaries.
    public static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        if sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) { return false }
        return sample.contains(0)
    }
}

/// Maps UTF-16 offsets to line numbers. Lines are separated by LF.
public struct LineIndex {
    public private(set) var starts: [Int] = [0]
    public let length: Int

    public init(_ string: String) {
        var starts = [0]
        var i = 0
        for unit in string.utf16 {
            i += 1
            if unit == 10 { starts.append(i) }
        }
        self.starts = starts
        self.length = i
    }

    public var lineCount: Int { starts.count }

    /// 0-based line containing `offset`.
    public func line(for offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Range of 0-based `line`, excluding its terminating newline.
    public func range(ofLine line: Int) -> NSRange {
        let l = max(0, min(line, starts.count - 1))
        let start = starts[l]
        let end = l + 1 < starts.count ? starts[l + 1] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }
}
