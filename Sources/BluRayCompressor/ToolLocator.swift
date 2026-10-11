import Foundation

struct ExternalTools {
    let ffmpeg: URL
    let ffprobe: URL
    let tsMuxeR: URL
}

enum ToolLocatorError: LocalizedError {
    case missing(name: String, installHint: String)

    var errorDescription: String? {
        switch self {
        case .missing(let name, let hint):
            if ToolLocator.isPackagedApp {
                return "\(name) is missing from the app. Download the app again and replace this copy."
            }
            return "\(name) not found on PATH.\n\n\(hint)"
        }
    }
}

enum ToolLocator {
    static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin"
    ]

    /// Directory inside the .app bundle where tools may be shipped alongside
    /// the executable. When the app is packaged with bundled ffmpeg/tsMuxeR,
    /// these take priority over anything on the user's PATH — so the
    /// recipient of a distributed build doesn't need Homebrew.
    static var bundledToolsDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin")
    }

    /// True when running from a built .app bundle rather than `swift run`.
    static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks ffmpeg which optional filters it was built with.
    static func capabilities(ffmpeg: URL) async -> BluRayEncoder.Capabilities {
        guard let result = try? await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-filters"]) else {
            return .none
        }
        let names = Set(result.stdout.split(separator: "\n").compactMap { line -> Substring? in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            return cols.count >= 2 ? cols[1] : nil
        })
        return BluRayEncoder.Capabilities(
            canTonemapHDR: names.contains("zscale") && names.contains("tonemap")
        )
    }

    static func locate() throws -> ExternalTools {
        let ffmpeg = try find(
            ["ffmpeg"],
            hint: "Install with: brew install ffmpeg"
        )
        let ffprobe = try find(
            ["ffprobe"],
            hint: "Install with: brew install ffmpeg"
        )
        let tsMuxeR = try find(
            ["tsMuxeR", "tsmuxer"],
            hint: "Install tsMuxeR from https://github.com/justdan96/tsMuxer/releases\n" +
                  "or via a Homebrew tap."
        )
        return ExternalTools(
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            tsMuxeR: tsMuxeR
        )
    }

    private static func find(_ names: [String], hint: String) throws -> URL {
        let fm = FileManager.default

        // 0. An explicit tools folder, for tests and development builds.
        if let dir = ProcessInfo.processInfo.environment["DISC_TOOLS_DIR"] {
            for name in names {
                let path = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }

        // 1. Bundled tools inside the .app take priority.
        if let bundled = bundledToolsDir {
            for name in names {
                let url = bundled.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        // 2. Known system-install paths.
        for name in names {
            for base in searchPaths {
                let path = "\(base)/\(name)"
                if fm.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }

        // 3. Login-shell `command -v` — picks up Homebrew's dynamic PATH,
        //    mise/asdf/direnv overrides, etc.
        for name in names {
            if let found = whichViaShell(name) {
                return found
            }
        }
        throw ToolLocatorError.missing(name: names.first ?? "tool",
                                       installHint: hint)
    }

    private static func whichViaShell(_ name: String) -> URL? {
        // Pass the tool name as a positional argument rather than splicing
        // into the script string. The script string is a constant; the
        // user-controllable bit is the argument, so word-splitting and
        // shell metacharacters in `name` can't break out of `"$1"`.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", "command -v -- \"$1\"", "--", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty,
              FileManager.default.isExecutableFile(atPath: out)
        else {
            return nil
        }
        return URL(fileURLWithPath: out)
    }
}
