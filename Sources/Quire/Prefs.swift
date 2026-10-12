import AppKit
import QuireCore

extension Notification.Name {
    static let prefsChanged = Notification.Name("QuirePrefsChanged")
    static let languagesChanged = Notification.Name("QuireLanguagesChanged")
}

/// Global editor preferences, persisted in UserDefaults.
enum Prefs {
    /// ~/Library/Application Support/Quire
    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quire")
    }

    private static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "showLineNumbers": true, "softWrap": true, "showInvisibles": false,
            "showPageGuide": true, "pageGuideColumn": 80, "highlightCurrentLine": true,
            "expandTabs": true, "tabWidth": 4, "fontSize": 13.0, "autoIndent": true,
            "autoComplete": false, "gitIntegration": true,
        ])
    }

    private static func set(_ v: Any, _ key: String) {
        d.set(v, forKey: key)
        NotificationCenter.default.post(name: .prefsChanged, object: nil)
    }

    static var showLineNumbers: Bool { get { d.bool(forKey: "showLineNumbers") } set { set(newValue, "showLineNumbers") } }
    static var softWrap: Bool { get { d.bool(forKey: "softWrap") } set { set(newValue, "softWrap") } }
    static var showInvisibles: Bool { get { d.bool(forKey: "showInvisibles") } set { set(newValue, "showInvisibles") } }
    static var showPageGuide: Bool { get { d.bool(forKey: "showPageGuide") } set { set(newValue, "showPageGuide") } }
    static var pageGuideColumn: Int { get { d.integer(forKey: "pageGuideColumn") } set { set(newValue, "pageGuideColumn") } }
    static var highlightCurrentLine: Bool { get { d.bool(forKey: "highlightCurrentLine") } set { set(newValue, "highlightCurrentLine") } }
    static var expandTabs: Bool { get { d.bool(forKey: "expandTabs") } set { set(newValue, "expandTabs") } }
    static var autoIndent: Bool { get { d.bool(forKey: "autoIndent") } set { set(newValue, "autoIndent") } }
    static var autoComplete: Bool { get { d.bool(forKey: "autoComplete") } set { set(newValue, "autoComplete") } }
    static var gitIntegration: Bool { get { d.bool(forKey: "gitIntegration") } set { set(newValue, "gitIntegration") } }
    static var tabWidth: Int { get { max(1, d.integer(forKey: "tabWidth")) } set { set(newValue, "tabWidth") } }
    static var fontSize: CGFloat { get { CGFloat(d.double(forKey: "fontSize")) } set { set(Double(min(72, max(6, newValue))), "fontSize") } }

    static var font: NSFont {
        if let name = d.string(forKey: "fontName"), let f = NSFont(name: name, size: fontSize) { return f }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static func setFont(_ font: NSFont) {
        d.set(font.fontName, forKey: "fontName")
        fontSize = font.pointSize
    }
}

/// Colours adapt to light/dark appearance at draw time.
enum Theme {
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        let l = hex(light), d = hex(dark)
        return NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }

    static let background = dyn(0xFFFFFF, 0x1F2023)
    static let text = dyn(0x1D1D1F, 0xD8D8DA)
    static let gutterBackground = dyn(0xF6F6F8, 0x26272B)
    static let gutterText = dyn(0xA0A0A6, 0x66666C)
    static let gutterCurrent = dyn(0x3C3C43, 0xC8C8CC)
    static let currentLine = dyn(0xF0F5FF, 0x2B2E35)
    static let pageGuide = dyn(0xE4E4E8, 0x35363B)
    static let invisibles = dyn(0xC4C4CA, 0x4E4F55)
    static let selection = dyn(0xB4D5FE, 0x3F5778)
    static let foldCapsule = dyn(0xE2E6EE, 0x3A3D45)
    static let foldCapsuleText = dyn(0x5A5F6B, 0xB0B4BE)
    static let gitAdded = dyn(0x34A853, 0x3FB950)
    static let gitModified = dyn(0x2F7BEA, 0x4C8DFF)
    static let gitDeleted = dyn(0xD93025, 0xF85149)

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .type: return type
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .preprocessor: return preprocessor
        case .tag: return tag
        case .attribute: return attribute
        case .variable: return variable
        case .heading: return heading
        case .emphasis: return emphasis
        case .link: return link
        }
    }

    static let keyword = dyn(0xA626A4, 0xF471B9)
    static let type = dyn(0x0E6E8A, 0x67D4F0)
    static let string = dyn(0xC0362C, 0xF58A73)
    static let comment = dyn(0x6A7380, 0x79808C)
    static let number = dyn(0x2D3FD6, 0xD9C46C)
    static let preprocessor = dyn(0x8A4B10, 0xF0A35E)
    static let tag = dyn(0x1F5FB0, 0x6FB0F5)
    static let attribute = dyn(0x8A6A00, 0xB892F0)
    static let variable = dyn(0x2C7A6E, 0x6CC4B0)
    static let heading = dyn(0x1F5FB0, 0x7FB8FF)
    static let emphasis = dyn(0x8E3E9E, 0xD7A0E6)
    static let link = dyn(0x1665D8, 0x66A6FF)
}
