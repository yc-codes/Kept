import CryptoKit
import Foundation

public enum ItemKind: String, CaseIterable, Sendable {
    case image, text, link

    public var label: String {
        switch self {
        case .image: return "Image"
        case .text: return "Text"
        case .link: return "Link"
        }
    }
}

public enum CaptureMethod: String, Sendable {
    case snip, clipboard, manual, connector

    public var label: String {
        switch self {
        case .snip: return "Region snip"
        case .clipboard: return "Copied"
        case .manual: return "Saved manually"
        case .connector: return "Connector"
        }
    }
}

public enum ItemFilter: String, CaseIterable, Identifiable, Sendable {
    case all, snips, images, links, text, favorites

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All Items"
        case .snips: return "Snips"
        case .images: return "Images"
        case .links: return "Links"
        case .text: return "Text"
        case .favorites: return "Favorites"
        }
    }

    public var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .snips: return "camera.viewfinder"
        case .images: return "photo"
        case .links: return "link"
        case .text: return "text.alignleft"
        case .favorites: return "star"
        }
    }

    var whereClause: String {
        switch self {
        case .all: return "1=1"
        case .snips: return "i.method='snip'"
        case .images: return "i.kind='image'"
        case .links: return "i.kind='link'"
        case .text: return "i.kind='text'"
        case .favorites: return "i.favorite=1"
        }
    }
}

public struct Item: Identifiable, Hashable, Sendable {
    /// Stable identifier, safe to cite from an agent (`kept://item/<id>`).
    public var id: String
    public var kind: ItemKind
    public var method: CaptureMethod
    public var createdAt: Date
    public var title: String
    /// Copied text, or the URL for links. Empty for images.
    public var text: String
    /// File name inside the assets folder (images only).
    public var assetName: String?
    public var width: Int
    public var height: Int
    public var sourceApp: String?
    public var sourceBundleID: String?
    public var hash: String
    /// The user's own note: why they saved it.
    public var note: String
    /// Text recognised inside an image.
    public var ocrText: String
    /// Model-generated description, kept separate from the user's note.
    public var aiDescription: String
    public var favorite: Bool
    public var ocrDone: Bool

    public init(
        id: String = Item.newID(), kind: ItemKind, method: CaptureMethod, createdAt: Date = Date(),
        title: String, text: String = "", assetName: String? = nil, width: Int = 0, height: Int = 0,
        sourceApp: String? = nil, sourceBundleID: String? = nil, hash: String, note: String = "",
        ocrText: String = "", aiDescription: String = "", favorite: Bool = false, ocrDone: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.method = method
        self.createdAt = createdAt
        self.title = title
        self.text = text
        self.assetName = assetName
        self.width = width
        self.height = height
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.hash = hash
        self.note = note
        self.ocrText = ocrText
        self.aiDescription = aiDescription
        self.favorite = favorite
        self.ocrDone = ocrDone
    }

    public static func newID() -> String {
        let alphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")
        return "k" + String((0..<9).map { _ in alphabet.randomElement()! })
    }

    public var assetURL: URL? { assetName.map { KeptPaths.assets.appendingPathComponent($0) } }
    public var thumbURL: URL? { kind == .image ? KeptPaths.thumbs.appendingPathComponent(id + ".jpg") : nil }
    public var deepLink: String { "kept://item/\(id)" }
    public var linkURL: URL? { kind == .link ? URL(string: text) : nil }
}

public enum Hashing {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ string: String) -> String { sha256(Data(string.utf8)) }
}

public enum KeptPaths {
    /// `KEPT_HOME` overrides the library location (used for testing).
    public static let root: URL = {
        if let custom = ProcessInfo.processInfo.environment["KEPT_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kept", isDirectory: true)
    }()

    public static var database: URL { root.appendingPathComponent("kept.sqlite") }
    public static var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }
    public static var thumbs: URL { root.appendingPathComponent("thumbs", isDirectory: true) }

    public static func ensure() throws {
        for dir in [root, assets, thumbs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
