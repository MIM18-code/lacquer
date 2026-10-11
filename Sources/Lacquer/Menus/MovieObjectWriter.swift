import Foundation

/// One HDMV navigation command: 4 bytes of opcode, then destination and
/// source operands. The same 12-byte form appears in MovieObject.bdmv and in
/// the button commands of an Interactive Graphics stream.
///
/// Opcode layout (libbluray `hdmv_insn.h`, `mobj_parse_cmd`):
///   byte 0: operand count (3 bits), group (2), sub-group (3)
///   byte 1: immediate flag for operand 1, for operand 2, 2 reserved, branch option (4)
///   byte 2: 4 reserved, compare option (4)
///   byte 3: 3 reserved, set option (5)
/// Operands without the immediate flag are register numbers: GPR n is n,
/// PSR n is 0x80 | n.
struct NavCommand: Equatable, Sendable {
    var opcode: UInt32
    var destination: UInt32
    var source: UInt32

    var bytes: [UInt8] {
        var w = ByteWriter()
        w.u32(Int(opcode)); w.u32(Int(destination)); w.u32(Int(source))
        return w.bytes
    }

    /// GPR[register] = value.
    static func move(register: Int, value: Int) -> NavCommand {
        NavCommand(opcode: 0x5040_0001, destination: UInt32(register), source: UInt32(value))
    }

    /// Run the next command only if GPR[register] == value.
    static func ifEqual(register: Int, value: Int) -> NavCommand {
        NavCommand(opcode: 0x4840_0200, destination: UInt32(register), source: UInt32(value))
    }

    /// Continue at command `line` of the current movie object.
    static func goto(_ line: Int) -> NavCommand {
        NavCommand(opcode: 0x2081_0000, destination: UInt32(line), source: 0)
    }

    static func jumpObject(_ object: Int) -> NavCommand {
        NavCommand(opcode: 0x2180_0000, destination: UInt32(object), source: 0)
    }

    /// Titles are numbered from 1, as in index.bdmv.
    static func jumpTitle(_ title: Int) -> NavCommand {
        NavCommand(opcode: 0x2181_0000, destination: UInt32(title), source: 0)
    }

    /// Plays playlist `xxxxx.mpls` from the start. Movie objects only:
    /// players refuse playlist changes from button commands.
    static func playPlaylist(_ playlist: Int) -> NavCommand {
        NavCommand(opcode: 0x2280_0000, destination: UInt32(playlist), source: 0)
    }

    /// Plays a playlist from the mark whose index is in GPR[markRegister].
    static func playPlaylist(_ playlist: Int, markInRegister markRegister: Int) -> NavCommand {
        NavCommand(opcode: 0x4282_0000, destination: UInt32(playlist), source: UInt32(markRegister))
    }

    /// SetStream for the PG/TextST subtitle stream (1-based) and its display
    /// flag; audio, IG and angle are left alone.
    static func setSubtitleStream(_ number: Int, displayed: Bool) -> NavCommand {
        let dst = 0x8000 | (displayed ? 0x4000 : 0) | (number & 0xFFF)
        return NavCommand(opcode: 0x51C0_0001, destination: UInt32(dst), source: 0)
    }

    /// SetButtonPage selecting `button` on the current page. In a button
    /// command it ends the command list and redraws that button as selected.
    static func selectButton(_ button: Int) -> NavCommand {
        NavCommand(opcode: 0x51C0_0003, destination: 0x8000_0000 | UInt32(button & 0xFFFF), source: 0)
    }

    /// SetButtonPage in a movie object: stores the button to select (PSR10)
    /// and the IG page to show (PSR11) for the next menu that opens.
    static func setButtonPage(button: Int, page: Int) -> NavCommand {
        NavCommand(opcode: 0x51C0_0003, destination: 0x8000_0000 | UInt32(button & 0xFFFF),
                   source: 0x8000_0000 | UInt32(page & 0xFF))
    }
}

struct MovieObject: Equatable, Sendable {
    var commands: [NavCommand]
    /// The title can be resumed after a menu call. Set for the film, not
    /// for menus.
    var resumeIntention: Bool = false
    var menuCallMask: Bool = false
    var titleSearchMask: Bool = false
}

/// Writes BDMV/MovieObject.bdmv (layout as parsed by libbluray `mobj_parse.c`
/// and written by tsMuxeR `blurayHelper.cpp`).
enum MovieObjectWriter {
    static func data(_ objects: [MovieObject]) -> Data {
        var w = ByteWriter()
        w.ascii("MOBJ", length: 4)
        w.ascii("0200", length: 4)
        w.u32(0)            // extension_data_start_address
        w.zeros(28)         // reserved
        let length = w.reserve(4)
        w.u32(0)            // reserved
        w.u16(objects.count)
        for object in objects {
            var flags = 0
            if object.resumeIntention { flags |= 0x8000 }
            if object.menuCallMask { flags |= 0x4000 }
            if object.titleSearchMask { flags |= 0x2000 }
            w.u16(flags)
            w.u16(object.commands.count)
            for command in object.commands { w.append(command.bytes) }
        }
        w.patchLength(at: length, width: 4)
        return w.data
    }
}
