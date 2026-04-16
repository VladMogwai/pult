import Foundation

// MARK: - MP4SeekParser
// Parses MP4 metadata to locate the nearest keyframe for a given time,
// then builds a self-contained SeekPrelude that can be prepended to the
// mdat payload so the TV receives a valid MP4 stream.
//
// Response layout the HTTP server assembles:
//   [ftyp (optional)] [moov with adjusted stco/co64] [mdat header] [file data from keyframe offset …]

struct MP4SeekParser {

    // MARK: - Public types

    struct SeekPrelude {
        let ftypData:   Data     // original ftyp atom bytes (empty if absent)
        var moovData:   Data     // moov atom bytes with patched chunk offsets
        let dataOffset: UInt64   // byte position in the original file to start mdat from
        let dataLength: UInt64   // = fileSize - dataOffset

        /// Bytes before the mdat payload in the synthesised response.
        var prefixLength: UInt64 {
            UInt64(ftypData.count) + UInt64(moovData.count) + 8   // +8 = mdat box header
        }
    }

    // MARK: - Public API

    /// Returns the SeekPrelude needed to build a valid seek response, or nil on failure.
    static func buildSeekPrelude(for time: TimeInterval, in fileURL: URL) -> SeekPrelude? {
        guard time > 0 else { return nil }
        guard let fh = FileHandle(forReadingAtPath: fileURL.path) else { return nil }
        defer { fh.closeFile() }
        guard
            let attrs    = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let fileSize = attrs[.size] as? UInt64, fileSize > 0
        else { return nil }

        let dataOffset = seekOffset(fh: fh, fileSize: fileSize, time: time)
        guard dataOffset > 0 else { return nil }

        // Locate ftyp and moov at top level.
        var ftypBox: Box?
        var moovBox: Box?
        scan(fh: fh, at: 0, size: fileSize) { name, box in
            if name == "ftyp" { ftypBox = box }
            if name == "moov" { moovBox = box; return false }
            return true
        }
        guard let moov = moovBox else { return nil }

        // Read raw box bytes.
        var ftypData = Data()
        if let ftyp = ftypBox {
            fh.seek(toFileOffset: ftyp.start)
            ftypData = fh.readData(ofLength: Int(ftyp.fullSize))
        }
        fh.seek(toFileOffset: moov.start)
        var moovData = fh.readData(ofLength: Int(moov.fullSize))
        guard moovData.count == Int(moov.fullSize) else { return nil }

        // Patch stco/co64 inside moovData:
        //   new_offset = original_offset - dataOffset + prefixLength
        // where prefixLength = ftypData.count + moovData.count + 8 (mdat header).
        let prefixSize = UInt64(ftypData.count) + UInt64(moovData.count) + 8
        adjustChunkOffsets(in: &moovData, seekOffset: dataOffset, prefixSize: prefixSize)

        return SeekPrelude(
            ftypData:   ftypData,
            moovData:   moovData,
            dataOffset: dataOffset,
            dataLength: fileSize - dataOffset
        )
    }

    // MARK: - Box abstraction

    private struct Box {
        let start:     UInt64   // file offset of the box header
        let dataStart: UInt64   // file offset of the box payload
        let dataSize:  UInt64
        var fullSize: UInt64 { dataStart - start + dataSize }
    }

    /// Scans direct child boxes within [offset, offset+limit).
    @discardableResult
    private static func scan(fh: FileHandle,
                              at offset: UInt64, size limit: UInt64,
                              _ body: (String, Box) -> Bool) -> Bool {
        let end = offset + limit
        var pos  = offset
        while pos + 8 <= end {
            fh.seek(toFileOffset: pos)
            let hdr = fh.readData(ofLength: 8)
            guard hdr.count == 8 else { return false }

            let rawSize = hdr.u32(0)
            let name    = String(bytes: hdr[4..<8], encoding: .isoLatin1) ?? "????"

            let hdrLen: UInt64
            let dataLen: UInt64
            switch rawSize {
            case 1:
                let ext = fh.readData(ofLength: 8)
                guard ext.count == 8 else { return false }
                let total = ext.u64(0)
                hdrLen = 16; dataLen = total > 16 ? total - 16 : 0
            case 0:
                hdrLen = 8; dataLen = end > pos + 8 ? end - pos - 8 : 0
            default:
                hdrLen = 8; dataLen = UInt64(rawSize) > 8 ? UInt64(rawSize) - 8 : 0
            }

            let box = Box(start: pos, dataStart: pos + hdrLen, dataSize: dataLen)
            if !body(name, box) { return true }
            let total = hdrLen + dataLen
            guard total > 0 else { return false }
            pos += total
        }
        return true
    }

    private static func child(_ name: String, of parent: Box, fh: FileHandle) -> Box? {
        var found: Box?
        scan(fh: fh, at: parent.dataStart, size: parent.dataSize) { n, b in
            if n == name { found = b; return false }
            return true
        }
        return found
    }

    // MARK: - Seek offset computation

    private static func seekOffset(fh: FileHandle, fileSize: UInt64, time: TimeInterval) -> UInt64 {
        var moovBox: Box?
        scan(fh: fh, at: 0, size: fileSize) { n, b in
            if n == "moov" { moovBox = b; return false }
            return true
        }
        guard let moov = moovBox                          else { return 0 }
        guard let trak = videoTrak(in: moov, fh: fh)     else { return 0 }
        guard let mdia = child("mdia", of: trak, fh: fh) else { return 0 }
        guard let mdhd = child("mdhd", of: mdia, fh: fh) else { return 0 }
        let ts = readTimescale(fh: fh, mdhd: mdhd)
        guard ts > 0                                       else { return 0 }
        guard let minf = child("minf", of: mdia, fh: fh)  else { return 0 }
        guard let stbl = child("stbl", of: minf, fh: fh)  else { return 0 }
        guard let stts = child("stts", of: stbl, fh: fh)  else { return 0 }

        var sample = sampleAt(time: time, timescale: ts, fh: fh, stts: stts)
        if let stss = child("stss", of: stbl, fh: fh) {
            sample = keyframeBefore(sample: sample, fh: fh, stss: stss)
        }
        guard let stsc = child("stsc", of: stbl, fh: fh) else { return 0 }
        let chunk = chunkContaining(sample: sample, fh: fh, stsc: stsc)
        guard chunk >= 1 else { return 0 }
        if let stco = child("stco", of: stbl, fh: fh) {
            return readChunkOffset(chunk: chunk, fh: fh, box: stco, wide: false)
        }
        if let co64 = child("co64", of: stbl, fh: fh) {
            return readChunkOffset(chunk: chunk, fh: fh, box: co64, wide: true)
        }
        return 0
    }

    // MARK: - Video trak

    private static func videoTrak(in moov: Box, fh: FileHandle) -> Box? {
        var found: Box?
        scan(fh: fh, at: moov.dataStart, size: moov.dataSize) { name, box in
            if name == "trak", isVideoTrak(box, fh: fh) { found = box; return false }
            return true
        }
        return found
    }

    private static func isVideoTrak(_ trak: Box, fh: FileHandle) -> Bool {
        guard let mdia = child("mdia", of: trak, fh: fh),
              let hdlr = child("hdlr", of: mdia, fh: fh) else { return false }
        // hdlr: version(1)+flags(3)+pre_defined(4)+handler_type(4)
        fh.seek(toFileOffset: hdlr.dataStart + 8)
        let d = fh.readData(ofLength: 4)
        return String(bytes: d, encoding: .isoLatin1) == "vide"
    }

    // MARK: - mdhd timescale

    private static func readTimescale(fh: FileHandle, mdhd: Box) -> UInt32 {
        fh.seek(toFileOffset: mdhd.dataStart)
        let v = fh.readData(ofLength: 1)
        guard v.count == 1 else { return 0 }
        let skip: UInt64 = v[0] == 1 ? 20 : 12
        fh.seek(toFileOffset: mdhd.dataStart + skip)
        let d = fh.readData(ofLength: 4)
        guard d.count == 4 else { return 0 }
        return d.u32(0)
    }

    // MARK: - stts → sample index

    private static func sampleAt(time: TimeInterval, timescale: UInt32,
                                  fh: FileHandle, stts: Box) -> UInt32 {
        let targetTick = UInt64(time * Double(timescale))
        fh.seek(toFileOffset: stts.dataStart + 4)
        let c = fh.readData(ofLength: 4)
        guard c.count == 4 else { return 1 }
        let entryCount = c.u32(0)
        var tick: UInt64 = 0; var sample: UInt32 = 1
        for _ in 0..<entryCount {
            let e = fh.readData(ofLength: 8)
            guard e.count == 8 else { break }
            let sc = e.u32(0); let delta = e.u32(4)
            guard delta > 0 else { sample += sc; continue }
            let range = UInt64(sc) * UInt64(delta)
            if targetTick < tick + range {
                return sample + UInt32((targetTick - tick) / UInt64(delta))
            }
            tick += range; sample += sc
        }
        return max(1, sample > 1 ? sample - 1 : 1)
    }

    // MARK: - stss → nearest keyframe ≤ sample

    private static func keyframeBefore(sample: UInt32, fh: FileHandle, stss: Box) -> UInt32 {
        fh.seek(toFileOffset: stss.dataStart + 4)
        let c = fh.readData(ofLength: 4)
        guard c.count == 4 else { return 1 }
        let count = c.u32(0)
        var last: UInt32 = 1
        for _ in 0..<count {
            let d = fh.readData(ofLength: 4)
            guard d.count == 4 else { break }
            let s = d.u32(0)
            if s > sample { break }
            last = s
        }
        return last
    }

    // MARK: - stsc → chunk for sample

    private static func chunkContaining(sample: UInt32, fh: FileHandle, stsc: Box) -> UInt32 {
        fh.seek(toFileOffset: stsc.dataStart + 4)
        let c = fh.readData(ofLength: 4)
        guard c.count == 4 else { return 0 }
        let count = c.u32(0); guard count > 0 else { return 0 }
        struct E { let fc: UInt32; let spc: UInt32 }
        var entries = [E](); entries.reserveCapacity(Int(min(count, 4096)))
        for _ in 0..<count {
            let e = fh.readData(ofLength: 12)
            guard e.count == 12 else { break }
            entries.append(E(fc: e.u32(0), spc: e.u32(4)))
        }
        var base: UInt32 = 1
        for i in 0..<entries.count {
            let spc = entries[i].spc; guard spc > 0 else { continue }
            let fc = entries[i].fc
            let nextFc: UInt32 = i + 1 < entries.count ? entries[i+1].fc : .max
            if nextFc == .max { return fc + (sample - base) / spc }
            let inRange = (nextFc - fc) &* spc
            if base &+ inRange > sample { return fc + (sample - base) / spc }
            base = base &+ inRange
        }
        return 0
    }

    // MARK: - stco/co64 → byte offset

    private static func readChunkOffset(chunk: UInt32, fh: FileHandle,
                                         box: Box, wide: Bool) -> UInt64 {
        let stride: UInt64 = wide ? 8 : 4
        fh.seek(toFileOffset: box.dataStart + 8 + UInt64(chunk - 1) * stride)
        if wide {
            let d = fh.readData(ofLength: 8); return d.count == 8 ? d.u64(0) : 0
        } else {
            let d = fh.readData(ofLength: 4); return d.count == 4 ? UInt64(d.u32(0)) : 0
        }
    }

    // MARK: - In-memory stco/co64 patch

    /// Walks the moov Data buffer and rewrites every stco/co64 entry:
    ///   - chunk at original offset >= seekOffset  →  original - seekOffset + prefixSize
    ///   - chunk before seek point                 →  0  (invalid; TV will skip)
    private static func adjustChunkOffsets(in data: inout Data,
                                            seekOffset: UInt64,
                                            prefixSize: UInt64) {
        let sz = data.count
        walkAndPatch(data: &data, at: 0, size: sz,
                     seekOffset: seekOffset, prefixSize: prefixSize)
    }

    private static func walkAndPatch(data: inout Data,
                                      at offset: Int, size: Int,
                                      seekOffset: UInt64, prefixSize: UInt64) {
        let end = offset + size
        var pos = offset
        while pos + 8 <= end {
            let rawSize = data.u32(pos)
            let name    = String(bytes: data[(pos+4)..<min(pos+8, data.count)],
                                 encoding: .isoLatin1) ?? ""
            var hdrLen = 8
            var dataLen = Int(rawSize) > 8 ? Int(rawSize) - 8 : 0
            if rawSize == 1 {
                guard pos + 16 <= end else { break }
                let t = data.u64(pos + 8)
                hdrLen = 16; dataLen = t > 16 ? Int(t - 16) : 0
            } else if rawSize == 0 {
                dataLen = end - pos - 8
            }
            let ds = pos + hdrLen
            switch name {
            case "trak", "mdia", "minf", "stbl":
                walkAndPatch(data: &data, at: ds, size: dataLen,
                             seekOffset: seekOffset, prefixSize: prefixSize)
            case "stco":
                patchOffsets(data: &data, at: ds, wide: false,
                             seekOffset: seekOffset, prefixSize: prefixSize)
            case "co64":
                patchOffsets(data: &data, at: ds, wide: true,
                             seekOffset: seekOffset, prefixSize: prefixSize)
            default: break
            }
            let total = hdrLen + dataLen; guard total > 0 else { break }
            pos += total
        }
    }

    private static func patchOffsets(data: inout Data, at base: Int, wide: Bool,
                                      seekOffset: UInt64, prefixSize: UInt64) {
        guard base + 8 <= data.count else { return }
        let count  = Int(data.u32(base + 4))
        let stride = wide ? 8 : 4
        var pos    = base + 8
        for _ in 0..<count {
            guard pos + stride <= data.count else { break }
            let orig: UInt64 = wide ? data.u64(pos) : UInt64(data.u32(pos))
            let adj  = orig >= seekOffset ? orig - seekOffset + prefixSize : 0
            if wide { data.writeU64(adj, at: pos) }
            else    { data.writeU32(UInt32(min(adj, UInt64(UInt32.max))), at: pos) }
            pos += stride
        }
    }
}

// MARK: - Data helpers (big-endian, bounds-checked)

extension Data {
    func u32(_ i: Int) -> UInt32 {
        guard i + 4 <= count else { return 0 }
        return UInt32(self[i]) << 24 | UInt32(self[i+1]) << 16
             | UInt32(self[i+2]) << 8  | UInt32(self[i+3])
    }
    func u64(_ i: Int) -> UInt64 {
        guard i + 8 <= count else { return 0 }
        let hi = UInt64(self[i]) << 56 | UInt64(self[i+1]) << 48
               | UInt64(self[i+2]) << 40 | UInt64(self[i+3]) << 32
        let lo = UInt64(self[i+4]) << 24 | UInt64(self[i+5]) << 16
               | UInt64(self[i+6]) << 8  | UInt64(self[i+7])
        return hi | lo
    }
    mutating func writeU32(_ v: UInt32, at i: Int) {
        guard i + 4 <= count else { return }
        self[i] = UInt8(v >> 24 & 0xFF); self[i+1] = UInt8(v >> 16 & 0xFF)
        self[i+2] = UInt8(v >> 8 & 0xFF); self[i+3] = UInt8(v & 0xFF)
    }
    mutating func writeU64(_ v: UInt64, at i: Int) {
        writeU32(UInt32(v >> 32), at: i)
        writeU32(UInt32(v & 0xFFFF_FFFF), at: i + 4)
    }
}
