import Foundation

/// BDMV/index.bdmv: which movie object runs on disc insertion (First
/// Playback), on the remote's Top Menu key, and for each numbered title.
/// Layout as parsed by libbluray `index_parse.c`.
struct IndexTable: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var movieObject: Int
        /// HDMV playback type: interactive for menus, movie for the film.
        var interactive: Bool
    }

    var firstPlayback: Entry
    var topMenu: Entry
    /// Title 1 is `titles[0]`.
    var titles: [Entry]
}

enum IndexWriter {
    static func data(_ table: IndexTable) -> Data {
        var w = ByteWriter()
        w.ascii("INDX", length: 4)
        w.ascii("0200", length: 4)
        let indexesStart = w.reserve(4)
        w.u32(0)                        // extension_data_start_address
        w.zeros(24)                     // reserved, up to byte 40

        // AppInfoBDMV: 34 bytes. Zero means no 3D output preference, no
        // content flag, video format and frame rate left to the playlists.
        w.u32(34)
        w.zeros(34)

        w.patch(indexesStart, width: 4, value: w.count)
        let length = w.reserve(4)
        writeObject(&w, table.firstPlayback)
        writeObject(&w, table.topMenu)
        w.u16(table.titles.count)
        for title in table.titles {
            // access_type 0 (in the reserved word): the title can be
            // searched for and appears in the player's title list.
            writeObject(&w, title)
        }
        w.patchLength(at: length, width: 4)
        return w.data
    }

    /// 12 bytes: object_type HDMV (1) in the top two bits, then
    /// playback_type, the movie object id and 32 reserved bits.
    private static func writeObject(_ w: inout ByteWriter, _ e: IndexTable.Entry) {
        w.u32(1 << 30)
        w.u16(e.interactive ? 0x4000 : 0)
        w.u16(e.movieObject)
        w.u32(0)
    }
}
