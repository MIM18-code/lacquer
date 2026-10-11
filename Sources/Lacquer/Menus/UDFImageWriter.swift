import Foundation

/// Writes a BDMV folder as a UDF 2.50 disc image, the format Blu-ray
/// players and duplicators require (hdiutil only writes UDF 1.50).
///
/// A Swift port of tsMuxeR 2.7.0's `IsoWriter` (iso_writer.cpp), the writer
/// Lacquer already relies on for film-only ISOs. Same layout: volume
/// recognition at 32K, descriptors at 64K/128K/512K, a physical partition
/// from 576K holding a metadata partition (main copy at 640K, mirror at the
/// end), the files' data in between, and closing anchors. With
/// `Header.reproducible` and tsMuxeR's file order the output matches
/// tsMuxeR's `--constant-iso-hdr` image byte for byte.
///
/// Disc menus need this because tsMuxeR only writes ISOs of what it muxed
/// itself; the menu clips and navigation files are added afterwards.
final class UDFImageWriter {
    struct Header {
        var applicationID: String
        var implementationID: String
        var time: time_t
        var volumeID: UInt32

        static func normal() -> Header {
            let id = UInt32.random(in: 0...UInt32.max)
            return Header(applicationID: "*Lacquer", implementationID: "*Lacquer " + String(id, radix: 16),
                          time: Darwin.time(nil), volumeID: UInt32.random(in: 0...UInt32.max))
        }

        static let reproducible = Header(applicationID: "*tsMuxeR", implementationID: "*tsMuxeR",
                                         time: 1, volumeID: 1_593_630_000)
    }

    enum WriteError: LocalizedError {
        case io(String)
        case tooManyEntries(String)

        var errorDescription: String? {
            switch self {
            case .io(let m): return "Writing the disc image failed: \(m)"
            case .tooManyEntries(let m): return "The disc image can't hold this layout: \(m)"
            }
        }
    }

    // MARK: - Constants (iso_writer.h)

    static let sectorSize = 2048
    static let allocBlockSize = 65_536
    static let metadataStartAddr = 640 * 1024 / 2048
    static let maxExtentSize: Int64 = 0x4000_0000
    static let nextExtentFlag: UInt32 = 0xC000_0000
    static let metaBlockPerData: Int64 = 16_000_000_000
    static let maxExtentsInFileEntry = (2048 - 216 - 32) / 16

    enum FileType: UInt8 {
        case directory = 4
        case file = 5
        case systemStreamDirectory = 13
        case realtimeFile = 249
        case metadata = 250
        case metadataMirror = 251

        var isFile: Bool { self == .file || self == .realtimeFile }
    }

    final class Entry {
        let parent: Entry?
        let objectID: UInt8
        let type: FileType
        var name = ""
        var sector = 0
        var sectorsUsed = 0
        var extents: [(lbn: Int, size: Int64)] = []
        var size: Int64 = 0
        var subdirectories: [Entry] = []
        var files: [Entry] = []

        init(parent: Entry?, objectID: UInt8, type: FileType) {
            self.parent = parent; self.objectID = objectID; self.type = type
        }
    }

    // MARK: - State

    private let handle: FileHandle
    private let header: Header
    /// Polled between 4 MB writes; true stops the copy with CancellationError.
    var isCancelled: () -> Bool = { false }
    private var volumeLabel = " "
    private var nextObjectID: Int = 16
    private var totalFiles = 0
    private var totalDirectories = 0
    private let root: Entry
    private let systemStream: Entry
    private let mappingFile: Entry
    private var partitionStart = 0
    private var partitionEnd = 0
    private var metadataLength = 0x30000
    private var metadataLBN = 0
    private var metadataMirrorLBN = 0
    private var systemStreamLBN = 0
    private var tagBase = 0
    private var currentMetadataPos = 0
    private var lastWrittenObjectID = -1
    private var mapping: [UInt8: (parent: Int, lbn: Int)] = [:]

    // MARK: - Whole-folder convenience

    /// Writes `folder` (holding BDMV/ and CERTIFICATE/) as a UDF 2.50 image,
    /// in the order tsMuxeR writes a disc: its directory set, the streams,
    /// index and movie objects, clip information, playlists, then anything
    /// else in the folder.
    static func writeImage(of folder: URL, to iso: URL, label: String,
                           header: Header = .normal(),
                           isCancelled: @escaping () -> Bool = { false }) throws {
        let fm = FileManager.default
        var files: [String] = []
        if let walker = fm.enumerator(atPath: folder.path) {
            for case let rel as String in walker {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: folder.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue {
                    if !rel.hasPrefix(".") && !rel.contains("/.") { files.append(rel) }
                }
            }
        }
        func rank(_ path: String) -> (Int, String) {
            let name = (path as NSString).lastPathComponent
            let backup = path.contains("BACKUP/") ? 1 : 0
            switch true {
            case path.hasPrefix("BDMV/STREAM/"): return (0, path)
            case name == "index.bdmv": return (10 + backup, path)
            case name == "MovieObject.bdmv": return (20 + backup, path)
            case path.hasSuffix(".clpi"): return (30, name + "\(backup)")
            case path.hasSuffix(".mpls"): return (40, name + "\(backup)")
            default: return (50, path)
            }
        }
        files.sort { rank($0) < rank($1) }
        let total = files.reduce(Int64(0)) {
            $0 + ((try? fm.attributesOfItem(atPath: folder.appendingPathComponent($1).path)[.size] as? Int64) ?? 0)
        }

        let writer = try UDFImageWriter(url: iso, header: header, diskSize: total)
        writer.isCancelled = isCancelled
        writer.setVolumeLabel(label)
        for dir in ["BDMV/META", "BDMV/BDJO", "BDMV/JAR", "BDMV/BACKUP/BDJO", "BDMV/BACKUP/JAR",
                    "CERTIFICATE/BACKUP", "BDMV/AUXDATA", "BDMV/CLIPINF", "BDMV/PLAYLIST", "BDMV/STREAM",
                    "BDMV/BACKUP/CLIPINF", "BDMV/BACKUP/PLAYLIST"] {
            writer.createDirectory(dir)
        }
        for rel in files {
            try writer.addFile(rel, from: folder.appendingPathComponent(rel))
        }
        try writer.close()
    }

    // MARK: - Open

    init(url: URL, header: Header, diskSize: Int64) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forUpdating: url) else {
            throw WriteError.io("can't create \(url.path)")
        }
        handle = h
        self.header = header
        if diskSize > 0 {
            let blocks = 2 + Int((diskSize + Self.metaBlockPerData - 1) / Self.metaBlockPerData)
            metadataLength = Self.allocBlockSize * blocks
        }
        root = Entry(parent: nil, objectID: 0, type: .directory)
        systemStream = Entry(parent: nil, objectID: 0, type: .systemStreamDirectory)
        mappingFile = Entry(parent: systemStream, objectID: 0, type: .file)
        mappingFile.name = "*UDF Unique ID Mapping Data"
        systemStream.files.append(mappingFile)

        try writeZeroSectors(16)                        // 32K system area
        try writeVolumeStructure("BEA01")
        try writeVolumeStructure("NSR03")
        try writeVolumeStructure("TEA01")
        while try position() < 576 * 1024 { try writeZeroSectors(1) }
        partitionStart = try sectorPosition()
        tagBase = partitionStart
        try writeZeroSectors(32)                        // to 640K
        metadataLBN = try sectorPosition()
        let required = Self.metadataStartAddr + metadataLength / Self.sectorSize
        let current = try sectorPosition()
        if required > current { try writeZeroSectors(required - current) }
        try writeZeroSectors(Self.allocBlockSize / Self.sectorSize)   // mapping file
    }

    func setVolumeLabel(_ label: String) {
        volumeLabel = label.isEmpty ? "Blu-Ray" : label
    }

    // MARK: - Tree

    @discardableResult
    func createDirectory(_ path: String) -> Entry {
        var entry = root
        for part in path.split(separator: "/").map(String.init) {
            if let next = entry.subdirectories.first(where: { $0.name == part }) {
                entry = next
            } else {
                let dir = Entry(parent: entry, objectID: takeObjectID(), type: .directory)
                dir.name = part
                entry.subdirectories.append(dir)
                entry = dir
            }
        }
        return entry
    }

    private func takeObjectID() -> UInt8 {
        defer { nextObjectID += 1 }
        return UInt8(truncatingIfNeeded: nextObjectID)
    }

    /// Copies `source` into the image at `path` ("BDMV/STREAM/00000.m2ts").
    func addFile(_ path: String, from source: URL) throws {
        guard nextObjectID < 256 else { throw WriteError.tooManyEntries("more than 240 files and folders") }
        let parts = path.split(separator: "/").map(String.init)
        let dir = createDirectory(parts.dropLast().joined(separator: "/"))
        let type: FileType = path.hasSuffix(".m2ts") || path.hasSuffix(".ssif") ? .realtimeFile : .file
        let entry: Entry
        if let existing = dir.files.first(where: { $0.name == parts.last! }) {
            entry = existing
        } else {
            entry = Entry(parent: dir, objectID: takeObjectID(), type: type)
            entry.name = parts.last!
            dir.files.append(entry)
        }
        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw WriteError.io("can't read \(source.path)")
        }
        defer { try? input.close() }
        var pending = Data()
        let chunk = 4 * 1024 * 1024
        while true {
            if isCancelled() { throw CancellationError() }
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            try write(entry, data, pending: &pending)
        }
        try closeFile(entry, pending: pending)
    }

    /// FileEntryInfo::write: extend or start an extent, write whole sectors,
    /// keep the partial sector for later.
    private func write(_ entry: Entry, _ data: Data, pending: inout Data) throws {
        let len = Int64(data.count)
        if lastWrittenObjectID != Int(entry.objectID) || entry.extents.isEmpty {
            entry.extents.append((try absoluteSector(), len))
        } else if entry.extents[entry.extents.count - 1].size + len < Self.maxExtentSize {
            entry.extents[entry.extents.count - 1].size += len
        } else {
            entry.extents.append((try absoluteSector(), len))
        }
        lastWrittenObjectID = Int(entry.objectID)
        entry.size += len
        var bytes = pending + data
        let whole = bytes.count - bytes.count % Self.sectorSize
        if whole > 0 { try handle.write(contentsOf: bytes.prefix(whole)) }
        bytes = bytes.dropFirst(whole)
        pending = Data(bytes)
    }

    private func closeFile(_ entry: Entry, pending: Data) throws {
        guard !pending.isEmpty else { return }
        var sector = pending
        sector.append(Data(count: Self.sectorSize - pending.count))
        try handle.write(contentsOf: sector)
    }

    // MARK: - Close

    func close() throws {
        defer { try? handle.close() }
        while try position() % Int64(Self.allocBlockSize) != 62 * 1024 { try writeZeroSectors(1) }

        metadataMirrorLBN = try sectorPosition() + 1
        tagBase = partitionStart
        try writeExtendedFileEntry(namedStream: false, objectID: 0, type: .metadataMirror,
                                   length: Int64(metadataLength), position: metadataMirrorLBN - partitionStart,
                                   linkCount: 0)
        try writeZeroSectors(metadataLength / Self.sectorSize)
        partitionEnd = try sectorPosition()
        try writeZeroSectors(32)                        // room for the closing anchor

        try allocateMetadata()

        tagBase = metadataMirrorLBN
        try writeMetadata(at: metadataMirrorLBN)

        try seek(576 * 1024)
        tagBase = partitionStart
        try writeExtendedFileEntry(namedStream: false, objectID: 0, type: .metadata,
                                   length: Int64(metadataLength), position: metadataLBN - partitionStart,
                                   linkCount: 0)
        tagBase = metadataLBN                           // as tsMuxeR (and Scenarist) do
        try writeMetadata(at: metadataLBN)

        try writeDescriptors()
    }

    private func allocateMetadata() throws {
        systemStreamLBN = allocate(root, sector: 2)     // 0: file set descriptor, 1: terminator
        _ = allocate(systemStream, sector: systemStreamLBN)
        if systemStreamLBN + 3 > metadataLength / Self.sectorSize {
            throw WriteError.tooManyEntries("not enough metadata space")
        }
        try seek(Int64(Self.metadataStartAddr * Self.sectorSize + metadataLength))
        var w = LEWriter(size: 32 + 16 + 16 * mapping.count)
        w.charSpec(header.implementationID, 32)
        w.u32(0)
        w.u32(UInt32(mapping.count & 0xFFFF))
        w.u32(0); w.u32(0)
        for (id, m) in mapping.sorted(by: { $0.key < $1.key }) {
            w.u32(UInt32(id)); w.u32(UInt32(m.parent)); w.u32(UInt32(m.lbn))
            w.u16(1); w.u16(1)
        }
        var pending = Data()
        try write(mappingFile, Data(w.buffer), pending: &pending)
        try closeFile(mappingFile, pending: pending)
    }

    private func allocate(_ entity: Entry, sector: Int) -> Int {
        if entity.type.isFile && entity.objectID != 0 {
            totalFiles += 1
        } else if entity.type == .directory {
            totalDirectories += 1
        }
        entity.sector = sector
        entity.sectorsUsed = entity.type.isFile ? 1 : 2
        var next = sector + entity.sectorsUsed
        if entity.objectID != 0 {
            mapping[entity.objectID] = (entity.parent?.sector ?? 0, entity.sector)
        }
        for f in entity.files { next = allocate(f, sector: next) }
        for d in entity.subdirectories { next = allocate(d, sector: next) }
        return next
    }

    private func writeMetadata(at lbn: Int) throws {
        try seek(Int64(lbn) * Int64(Self.sectorSize))
        currentMetadataPos = lbn
        try writeFileSetDescriptor()
        try writeTerminatingDescriptor()
        try writeEntity(root)
        try writeEntity(systemStream)
    }

    private func writeEntity(_ entry: Entry) throws {
        try seek(Int64(currentMetadataPos + entry.sector) * Int64(Self.sectorSize))
        if entry.type.isFile {
            guard entry.extents.count <= Self.maxExtentsInFileEntry else {
                throw WriteError.tooManyEntries("\(entry.name) needs \(entry.extents.count) extents")
            }
            try writeExtendedFileEntry(namedStream: entry.name == "*UDF Unique ID Mapping Data",
                                       objectID: entry.objectID, type: entry.type, length: entry.size,
                                       position: entry.sector, linkCount: 1, extents: entry.extents)
        } else {
            try writeDirectory(entry)
        }
        for f in entry.files { try writeEntity(f) }
        for d in entry.subdirectories { try writeEntity(d) }
    }

    /// The directory's file entry, then one sector of file identifiers.
    private func writeDirectory(_ dir: Entry) throws {
        var w = LEWriter(size: Self.sectorSize)
        let here = try absoluteSector()
        // Parent entry.
        let tag = w.beginTag(257, location: here + 1)
        w.u16(1)
        w.u8(0x0A)                                       // parent, directory
        w.u8(0)
        w.longAD(0x800, UInt32(dir.parent?.sector ?? here), 1, UInt32(dir.parent?.objectID ?? 0))
        w.u16(0)
        w.u16(0)
        w.closeTag(tag)
        for child in dir.files + dir.subdirectories {
            let t = w.beginTag(257, location: here + 1)
            w.u16(1)
            w.u8(!child.type.isFile ? 0x02 : (dir.objectID == 0 ? 0x10 : 0))
            let name = Self.dstring(child.name, fieldLength: child.name.utf8.count + 2)
            w.u8(name.count - 1)
            w.longAD(0x800, UInt32(child.sector), 1, UInt32(child.objectID))
            w.u16(0)
            // tsMuxeR writes the whole d-string, steps back over its length
            // byte and pads; when no padding is needed the byte stays in
            // the buffer past the descriptor. Kept for identical output.
            w.bytes(name)
            w.seek(w.position - 1)
            w.pad(to: 4)
            w.closeTag(t)
        }
        guard w.position < Self.sectorSize else {
            throw WriteError.tooManyEntries("folder \(dir.name) has too many entries for one sector")
        }
        try writeExtendedFileEntry(namedStream: false, objectID: dir.objectID, type: dir.type,
                                   length: Int64(w.position), position: dir.sector + 1,
                                   linkCount: UInt16(dir.subdirectories.count + 1))
        try handle.write(contentsOf: Data(w.buffer))
    }

    // MARK: - Descriptors

    private func writeExtendedFileEntry(namedStream: Bool, objectID: UInt8, type: FileType, length: Int64,
                                        position: Int, linkCount: UInt16,
                                        extents: [(lbn: Int, size: Int64)]? = nil) throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(266, location: try absoluteSector())
        // ICB tag
        w.u32(0); w.u16(4); w.u16(0); w.u16(1); w.u8(0); w.u8(type.rawValue)
        w.zeros(6)
        var flags: UInt16 = type.isFile ? 0x21 : 0x20
        if namedStream { flags += 0x2000 }
        w.u16(flags)
        w.u32(0xFFFF_FFFF); w.u32(0xFFFF_FFFF)          // uid, gid
        switch type {
        case .metadata, .metadataMirror: w.u32(0)
        case .file, .realtimeFile: w.u32(0x1084)
        default: w.u32(0x14A5)
        }
        w.u16(linkCount)
        w.u8(0); w.u8(0); w.u32(0)
        w.u64(UInt64(length)); w.u64(UInt64(length))
        w.u64(UInt64((length + 2047) / 2048))
        for _ in 0..<4 { w.timestamp(header.time) }
        w.u32(1)                                        // checkpoint
        w.seek(169)
        w.raw(header.implementationID)
        w.seek(200)
        w.u8(objectID)
        w.seek(212)
        if !type.isFile {
            w.u32(8)
            w.u32(UInt32(truncatingIfNeeded: length))
            w.u32(UInt32(position))
            w.closeTag(tag, length: 224)
        } else if let extents {
            w.u32(UInt32(16 * extents.count))
            for e in extents { w.longAD(UInt32(e.size), UInt32(e.lbn), 0, 0) }
            w.closeTag(tag, length: 216 + 16 * extents.count)
        } else {
            w.u32(16)
            w.longAD(UInt32(truncatingIfNeeded: length), UInt32(position), 0, 0)
            w.closeTag(tag, length: 232)
        }
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeFileSetDescriptor() throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(256, location: try absoluteSector())
        w.timestamp(header.time)
        w.u16(3); w.u16(3); w.u32(1); w.u32(1); w.u32(0); w.u32(0)
        w.charSpec("OSTA Compressed Unicode", 64)
        w.bytes(Self.dstring(volumeLabel, fieldLength: 128))
        w.charSpec("OSTA Compressed Unicode", 64)
        w.bytes(Self.dstring(volumeLabel, fieldLength: 32))
        w.zeros(64)                                     // copyright, abstract
        w.longAD(0x800, 2, 1, 0)                        // root directory
        w.udfString("*OSTA UDF Compliant", 32)
        w.buffer[442] = 0x03                            // hard and soft write-protect
        w.longAD(0, 0, 0, 0)                            // next extent
        w.longAD(0x800, UInt32(systemStreamLBN), 1, 0)  // system stream directory
        w.closeTag(tag, length: 512)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeDescriptors() throws {
        tagBase = 0
        try seek(64 * 1024)
        try writeVolumeDescriptorSequence()
        try seek(128 * 1024)
        try writeLogicalVolumeIntegrity()
        try writeTerminatingDescriptor()
        try seek(512 * 1024)
        let anchorTarget = partitionEnd + Self.allocBlockSize / Self.sectorSize
        try writeAnchor(anchorTarget)

        let eof = Int64(partitionEnd) * Int64(Self.sectorSize)
        try seek(eof + Int64(Self.allocBlockSize - Self.sectorSize))
        try writeAnchor(anchorTarget)
        try writeVolumeDescriptorSequence()
        let fullSize = eof + 512 * 1024 + Int64(Self.allocBlockSize)
        while try position() < fullSize - Int64(Self.sectorSize) { try writeZeroSectors(1) }
        try writeAnchor(anchorTarget)
    }

    private func writeVolumeDescriptorSequence() throws {
        try writePrimaryVolumeDescriptor()
        try writeImplementationUseDescriptor()
        try writePartitionDescriptor()
        try writeLogicalVolumeDescriptor()
        try writeUnallocatedSpaceDescriptor()
        try writeTerminatingDescriptor()
    }

    private func writePrimaryVolumeDescriptor() throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(1, location: try absoluteSector())
        w.u32(0); w.u32(0)
        w.bytes(Self.dstring(volumeLabel, fieldLength: 32))
        w.u16(1); w.u16(1); w.u16(2); w.u16(2); w.u32(1); w.u32(1)
        let hex = String(header.volumeID, radix: 16).uppercased()
        let volumeSet = String(repeating: "0", count: max(0, 8 - hex.count)) + hex + "        " + volumeLabel
        w.bytes(Self.dstring(volumeSet, fieldLength: 128))
        w.seek(201); w.raw("OSTA Compressed Unicode")
        w.seek(265); w.raw("OSTA Compressed Unicode")
        w.seek(345); w.raw(header.applicationID)
        w.seek(376); w.timestamp(header.time)
        w.seek(389); w.raw(header.implementationID)
        w.seek(420); w.raw(header.applicationID)
        w.buffer[488] = 1
        w.closeTag(tag, length: 512)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeImplementationUseDescriptor() throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(4, location: try absoluteSector())
        w.u32(1)
        w.udfString("*UDF LV Info", 32)
        w.seek(53); w.raw("OSTA Compressed Unicode")
        w.seek(116); w.bytes(Self.dstring(volumeLabel, fieldLength: 128))
        w.seek(0x161); w.raw(header.implementationID)
        w.seek(0x180); w.raw(header.applicationID)
        w.closeTag(tag, length: 512)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writePartitionDescriptor() throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(5, location: try absoluteSector())
        w.u32(2); w.u16(1); w.u16(0)
        w.seek(25); w.raw("+NSR03")
        w.seek(184)
        w.u32(1)
        w.u32(UInt32(partitionStart))
        w.u32(UInt32(partitionEnd - partitionStart))
        w.seek(0xC5); w.raw(header.implementationID)
        w.seek(0xE4); w.raw(header.applicationID)
        w.closeTag(tag, length: 512)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeLogicalVolumeDescriptor() throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(6, location: try absoluteSector())
        w.u32(3)
        w.seek(21); w.raw("OSTA Compressed Unicode")
        w.seek(84); w.bytes(Self.dstring(volumeLabel, fieldLength: 128))
        w.u32(UInt32(Self.sectorSize))
        w.udfString("*OSTA UDF Compliant", 32)
        w.buffer[242] = 0x03
        w.buffer[249] = 0x10
        w.buffer[256] = 0x01
        w.buffer[264] = 0x46
        w.buffer[268] = 0x02
        w.seek(273); w.raw(header.implementationID)
        w.seek(304); w.raw(header.applicationID)
        w.seek(432); w.u32(0x8000); w.u32(0x40)
        // Partition map 1: the physical partition.
        w.u8(1); w.u8(6); w.u16(1); w.u16(0)
        // Partition map 2: the metadata partition.
        w.u8(2); w.u8(64)
        w.seek(450); w.udfString("*UDF Metadata Partition", 32)
        w.u16(1); w.u16(0); w.u16(0); w.u16(0)
        let mirror = UInt32(metadataMirrorLBN - 1 - partitionStart)
        w.u16(UInt16(mirror % 65536)); w.u16(UInt16(mirror / 65536))
        w.u16(0xFFFF); w.u16(0xFFFF)
        w.u16(0x20); w.u16(0); w.u16(0x20)
        w.u8(1)
        w.closeTag(tag, length: 510)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeUnallocatedSpaceDescriptor() throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(7, location: try absoluteSector())
        w.u32(4)
        w.closeTag(tag, length: 24)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeTerminatingDescriptor() throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(8, location: try absoluteSector())
        w.closeTag(tag, length: 512)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeLogicalVolumeIntegrity() throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(9, location: try absoluteSector())
        w.timestamp(header.time)
        w.u32(1); w.u32(0); w.u32(0)
        w.u32(UInt32(nextObjectID & 0xFF)); w.u32(0)
        w.seek(72)
        w.u32(2)
        w.u32(UInt32(46 + header.applicationID.utf8.count))
        w.u32(0); w.u32(0)
        w.u32(UInt32(partitionEnd - partitionStart))
        w.u32(UInt32(metadataLength / Self.sectorSize))
        w.seek(97); w.raw(header.implementationID)
        w.seek(0x80)
        w.u32(UInt32(totalFiles)); w.u32(UInt32(totalDirectories))
        w.u16(0x0250); w.u16(0x0250); w.u16(0x0250)
        w.raw(header.applicationID)
        w.closeTag(tag, length: 142 + header.applicationID.utf8.count)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeAnchor(_ reserveLocation: Int) throws {
        var w = LEWriter(size: Self.sectorSize)
        let tag = w.beginTag(2, location: try absoluteSector())
        w.u32(0x8000); w.u32(0x20); w.u32(0x8000); w.u32(UInt32(reserveLocation))
        w.closeTag(tag, length: 512)
        try handle.write(contentsOf: Data(w.buffer))
    }

    private func writeVolumeStructure(_ id: String) throws {
        var sector = [UInt8](repeating: 0, count: Self.sectorSize)
        sector[0] = 0
        for (i, c) in id.utf8.enumerated() { sector[1 + i] = c }
        sector[6] = 1
        try handle.write(contentsOf: Data(sector))
    }

    // MARK: - Positioning

    private func position() throws -> Int64 { Int64(try handle.offset()) }
    private func sectorPosition() throws -> Int { Int(try position() / Int64(Self.sectorSize)) }
    private func absoluteSector() throws -> Int { try sectorPosition() - tagBase }
    private func seek(_ offset: Int64) throws { try handle.seek(toOffset: UInt64(offset)) }

    private func writeZeroSectors(_ n: Int) throws {
        guard n > 0 else { return }
        let block = Data(count: Self.sectorSize * min(n, 512))
        var left = n
        while left > 0 {
            let k = min(left, 512)
            try handle.write(contentsOf: k == 512 ? block : Data(count: k * Self.sectorSize))
            left -= k
        }
    }

    // MARK: - Strings

    /// OSTA compressed Unicode d-string: compression id 8 (Latin-1) or 16
    /// (UTF-16BE), the characters, zero padding, then the length byte.
    static func dstring(_ s: String, fieldLength: Int) -> [UInt8] {
        guard !s.isEmpty else { return [UInt8](repeating: 0, count: fieldLength) }
        let room = fieldLength - 1
        var out: [UInt8]
        if s.unicodeScalars.allSatisfy({ $0.value < 0x100 }) {
            out = [8]
            for u in s.unicodeScalars where out.count < room { out.append(UInt8(u.value)) }
        } else {
            out = [16]
            for unit in s.utf16 where room - out.count >= 2 { out += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        }
        let length = out.count
        out += [UInt8](repeating: 0, count: room - out.count)
        out.append(UInt8(length))
        return out
    }
}

/// Little-endian sector builder for UDF descriptors.
private struct LEWriter {
    var buffer: [UInt8]
    var position = 0

    init(size: Int) { buffer = [UInt8](repeating: 0, count: size) }

    mutating func seek(_ at: Int) { position = at }
    mutating func u8(_ v: Int) { buffer[position] = UInt8(truncatingIfNeeded: v); position += 1 }
    mutating func u8(_ v: UInt8) { buffer[position] = v; position += 1 }
    mutating func u16(_ v: UInt16) { u8(Int(v & 0xFF)); u8(Int(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { u8(Int((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { u8(Int((v >> (8 * UInt64(i))) & 0xFF)) } }
    mutating func zeros(_ n: Int) { position += n }
    mutating func bytes(_ b: [UInt8]) { for x in b { u8(x) } }

    /// C string copy without moving the cursor's logical field (strcpy).
    mutating func raw(_ s: String) {
        for (i, c) in s.utf8.enumerated() { buffer[position + i] = c }
    }

    /// charspec: type 0 (CS0) then the name, `length` bytes in all.
    mutating func charSpec(_ s: String, _ length: Int) {
        for (i, c) in s.utf8.enumerated() { buffer[position + 1 + i] = c }
        position += length
    }

    /// regid with the UDF 2.50 revision suffix.
    mutating func udfString(_ s: String, _ length: Int) {
        for (i, c) in s.utf8.enumerated() { buffer[position + 1 + i] = c }
        buffer[position + length - 8] = 0x50
        buffer[position + length - 7] = 0x02
        position += length
    }

    mutating func longAD(_ length: UInt32, _ location: UInt32, _ partition: UInt16, _ uniqueID: UInt32) {
        u32(length); u32(location); u16(partition); u16(0); u32(uniqueID)
    }

    mutating func pad(to n: Int) { while position % n != 0 { u8(0) } }

    mutating func timestamp(_ t: time_t) {
        var time = t
        var local = tm(), utc = tm()
        localtime_r(&time, &local)
        gmtime_r(&time, &utc)
        var l = local, g = utc
        let zone = Int16(truncatingIfNeeded: (mktime(&l) - mktime(&g)) / 60)
        u16(UInt16(1 << 12) &+ (UInt16(bitPattern: zone) & 0x0FFF))
        u16(UInt16(local.tm_year + 1900))
        u8(Int(local.tm_mon + 1)); u8(Int(local.tm_mday)); u8(Int(local.tm_hour))
        u8(Int(local.tm_min)); u8(Int(local.tm_sec)); u8(0); u8(0); u8(0)
    }

    /// Descriptor tag: id, version 3, serial 1, location. Returns its offset.
    mutating func beginTag(_ id: UInt16, location: Int) -> Int {
        let at = position
        u16(id); u16(3); u8(0); u8(0); u16(1); u16(0); u16(0); u32(UInt32(truncatingIfNeeded: location))
        return at
    }

    /// CRC over the descriptor body and the tag checksum. `length` is the
    /// whole descriptor; nil means up to the cursor.
    mutating func closeTag(_ at: Int, length: Int? = nil) {
        let len = length ?? (position - at)
        let crc = Self.crc16(buffer[(at + 16)..<(at + len)])
        buffer[at + 8] = UInt8(crc & 0xFF); buffer[at + 9] = UInt8(crc >> 8)
        buffer[at + 10] = UInt8((len - 16) & 0xFF); buffer[at + 11] = UInt8((len - 16) >> 8)
        var sum: UInt8 = 0
        for i in 0..<16 where i != 4 { sum &+= buffer[at + i] }
        buffer[at + 4] = sum
    }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}
