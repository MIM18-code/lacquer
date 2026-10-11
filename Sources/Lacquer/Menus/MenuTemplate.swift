import Foundation

/// Everything the filmmaker chooses about a disc menu. The renderer turns
/// this plus the film, its chapter times and whether subtitles exist into a
/// `DiscMenu`. Saved with the job, so every field is plain Codable data.
struct MenuTemplate: Codable, Equatable, Sendable {
    /// Big title text. Empty draws no title.
    var title: String = ""
    /// Optional line under the title: year, director, festival.
    var subtitle: String = ""
    var background: MenuBackground = .filmFrame(seconds: 0)
    var style: MenuStylePreset = .fullFrame
    /// Wanted buttons. Play is always present. These two only take effect
    /// when the film allows them (2+ chapters, an .srt on the job).
    var includeScenes: Bool = true
    var includeSubtitles: Bool = true
    var scenePages = ScenePageSettings()
    /// Names for the scene buttons, by chapter. A blank or missing entry
    /// falls back to "Scene N". Blu-ray chapters themselves have no names;
    /// these only appear on the menu.
    var sceneNames: [String] = []

    func sceneName(_ chapter: Int) -> String {
        let name = chapter < sceneNames.count
            ? sceneNames[chapter].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return name.isEmpty ? "Scene \(chapter + 1)" : name
    }

    /// A starting template for a film: the file name as the title and a
    /// background frame a quarter of the way in, which is usually past the
    /// opening black and credits.
    static func suggested(forFilm film: URL, duration: Double?) -> MenuTemplate {
        var t = MenuTemplate()
        t.title = film.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if let duration, duration > 4 {
            t.background = .filmFrame(seconds: (duration * 0.25).rounded())
        }
        return t
    }
}

enum MenuBackground: Codable, Equatable, Sendable {
    /// A still from the film at this time.
    case filmFrame(seconds: Double)
    /// An image the filmmaker supplies (poster art, a key frame).
    case imageFile(path: String)
}

struct ScenePageSettings: Codable, Equatable, Sendable {
    /// Thumbnails per row, 2 or 3. Three is the most that keeps labels at
    /// 40 px or more.
    var columns: Int = 3
    /// Rows per page, 1 or 2.
    var rows: Int = 2
    /// Show "0:00" after the scene name.
    var showTimes: Bool = true

    static let columnRange = 2...3
    static let rowRange = 1...2

    var clamped: ScenePageSettings {
        ScenePageSettings(
            columns: min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound),
            rows: min(max(rows, Self.rowRange.lowerBound), Self.rowRange.upperBound),
            showTimes: showTimes
        )
    }

    var perPage: Int { clamped.columns * clamped.rows }
}

enum MenuStylePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullFrame
    case titleCard
    case typographic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullFrame: return "Full Frame"
        case .titleCard: return "Title Card"
        case .typographic: return "Typographic"
        }
    }

    /// One line for the picker.
    var blurb: String {
        switch self {
        case .fullFrame: return "Your frame edge to edge, a quiet title low on the left. For films with a strong key image."
        case .titleCard: return "Widescreen still with a centred title card and buttons in the black bar below. For a classic festival-disc feel."
        case .typographic: return "Black page, big type, the frame faded in on the right. For films without one iconic image."
        }
    }
}
