import Foundation

// The analysis-result part of the Auraliscope Bridge protocol (Bridge/PROTOCOL.md): how a RESULT payload is laid
// out, field by field. The framing (message header, message types) and the control messages are in
// BridgeProtocol.h; the field encoding below is the same for every message of protocol version 3.
//
// A payload is a sequence of fields, each:
//
//   tag u16 · kind u8 · flags u8 (0) · count u32 · count × size(kind) bytes · zero padding to a multiple of 4
//
// all little-endian. A receiver skips fields it does not know, so later schema versions can add fields; a known
// field with another kind, or with more elements than its limit, is ignored as if absent. Nothing here depends on
// the memory layout of a Swift or C type.

/// Element types of a field.
package enum WireKind: UInt8 {
    case u8 = 1, u32 = 2, u64 = 3, i64 = 4, f32 = 5, f64 = 6, utf8 = 7, bytes = 8

    package var size: Int {
        switch self {
        case .u8, .utf8, .bytes: return 1
        case .u32, .f32: return 4
        case .u64, .i64, .f64: return 8
        }
    }
}

package enum WireLimits {
    /// Largest payload of any message (`ABR_MAX_PAYLOAD`).
    package static let payload = 1 << 20
    /// Longest UTF-8 text field, in bytes.
    package static let text = 255
    /// Bytes of a field header.
    package static let fieldHeader = 8
}

/// Writes fields into caller-owned memory; never allocates. When a field does not fit, nothing of it is written
/// and `overflowed` is set; the caller sends nothing rather than a truncated payload.
package struct WireWriter {
    private let base: UnsafeMutableRawPointer
    private let capacity: Int
    package private(set) var count = 0
    package private(set) var overflowed = false

    package init(_ base: UnsafeMutableRawPointer, capacity: Int) {
        self.base = base
        self.capacity = capacity
    }

    /// Reserves one field of `elements` × `kind` and lets `fill` write its value (little-endian).
    private mutating func field(_ tag: UInt16, _ kind: WireKind, elements: Int, _ fill: (UnsafeMutableRawPointer) -> Void) {
        let bytes = elements * kind.size
        let padded = (bytes + 3) & ~3
        guard !overflowed, elements >= 0, count + WireLimits.fieldHeader + padded <= capacity else {
            overflowed = true
            return
        }
        let at = base + count
        at.storeBytes(of: tag.littleEndian, as: UInt16.self)
        at.storeBytes(of: kind.rawValue, toByteOffset: 2, as: UInt8.self)
        at.storeBytes(of: UInt8(0), toByteOffset: 3, as: UInt8.self)
        at.storeBytes(of: UInt32(elements).littleEndian, toByteOffset: 4, as: UInt32.self)
        fill(at + WireLimits.fieldHeader)
        if padded > bytes {
            (at + WireLimits.fieldHeader + bytes).initializeMemory(as: UInt8.self, repeating: 0, count: padded - bytes)
        }
        count += WireLimits.fieldHeader + padded
    }

    package mutating func u32(_ tag: UInt16, _ value: UInt32) {
        field(tag, .u32, elements: 1) { $0.storeBytes(of: value.littleEndian, as: UInt32.self) }
    }
    package mutating func u64(_ tag: UInt16, _ value: UInt64) {
        field(tag, .u64, elements: 1) { $0.storeBytes(of: value.littleEndian, as: UInt64.self) }
    }
    package mutating func f32(_ tag: UInt16, _ value: Float) {
        field(tag, .f32, elements: 1) { $0.storeBytes(of: value.bitPattern.littleEndian, as: UInt32.self) }
    }
    package mutating func f64(_ tag: UInt16, _ value: Double) {
        field(tag, .f64, elements: 1) { $0.storeBytes(of: value.bitPattern.littleEndian, as: UInt64.self) }
    }
    /// `elements` floats from `values`.
    package mutating func f32s(_ tag: UInt16, _ values: UnsafePointer<Float>, count elements: Int) {
        field(tag, .f32, elements: elements) { destination in
            for i in 0..<elements {
                destination.storeBytes(of: values[i].bitPattern.littleEndian, toByteOffset: 4 * i, as: UInt32.self)
            }
        }
    }
    package mutating func f32s(_ tag: UInt16, _ values: [Float]) {
        values.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { f32s(tag, base, count: buffer.count) } else { field(tag, .f32, elements: 0) { _ in } }
        }
    }
}

/// One field as read: its tag, kind, element count and value bytes (inside the payload).
package struct WireField {
    package let tag: UInt16
    package let kind: WireKind
    package let count: Int
    package let value: UnsafeRawBufferPointer

    package var u32: UInt32? { kind == .u32 && count == 1 ? UInt32(littleEndian: value.loadUnaligned(as: UInt32.self)) : nil }
    package var u64: UInt64? { kind == .u64 && count == 1 ? UInt64(littleEndian: value.loadUnaligned(as: UInt64.self)) : nil }
    package var f32: Float? {
        kind == .f32 && count == 1 ? Float(bitPattern: UInt32(littleEndian: value.loadUnaligned(as: UInt32.self))) : nil
    }
    package var f64: Double? {
        kind == .f64 && count == 1 ? Double(bitPattern: UInt64(littleEndian: value.loadUnaligned(as: UInt64.self))) : nil
    }
    package var text: String? { kind == .utf8 && count <= WireLimits.text ? String(decoding: value, as: UTF8.self) : nil }
    /// The floats, when this is a float field of at most `limit` elements.
    package func f32s(limit: Int) -> [Float]? {
        guard kind == .f32, count <= limit else { return nil }
        return (0..<count).map {
            Float(bitPattern: UInt32(littleEndian: value.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self)))
        }
    }
}

/// Reads the fields of one payload. A malformed field (a count that runs past the payload, an unknown kind) ends
/// the payload there: `malformed` is set, and the fields before it stand.
package struct WireReader: Sequence, IteratorProtocol {
    private let payload: UnsafeRawBufferPointer
    private var offset = 0
    package private(set) var malformed = false

    package init(_ payload: UnsafeRawBufferPointer) { self.payload = payload }

    package mutating func next() -> WireField? {
        guard offset + WireLimits.fieldHeader <= payload.count else {
            if offset != payload.count { malformed = true }
            return nil
        }
        let tag = UInt16(littleEndian: payload.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        let rawKind = payload[offset + 2]
        let elements = Int(UInt32(littleEndian: payload.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
        guard let kind = WireKind(rawValue: rawKind), elements <= WireLimits.payload else {
            malformed = true
            return nil
        }
        let bytes = elements * kind.size
        let padded = (bytes + 3) & ~3
        let start = offset + WireLimits.fieldHeader
        guard start + padded <= payload.count else {
            malformed = true
            return nil
        }
        offset = start + padded
        return WireField(tag: tag, kind: kind, count: elements,
                         value: UnsafeRawBufferPointer(rebasing: payload[start..<(start + bytes)]))
    }
}

/// Tags of a RESULT payload, analysis schema 1. Per-channel arrays hold one value per channel, in the insert's
/// channel order (mono: 1; stereo: L, R). Levels are linear amplitude (1 = full scale); loudness is in LUFS, with
/// −100 for "no value yet" (and −1 for a loudness range not yet measurable); spectra and band levels in dBFS, with
/// −120 for silence.
package enum ResultTag: UInt16 {
    // Stream and timing
    case subscription = 1          // u32: the SUBSCRIBE this result answers
    case schema = 2                // u32: analysis schema (1)
    case generation = 3            // u32: analysis generation: a new one after a reset or a format change
    case formatEpoch = 4           // u32: the plugin's format epoch the generation analyses
    case sampleRate = 5            // f64: Hz
    case channels = 6              // u32: 1 or 2
    case layout = 7                // u32: ABR_LAYOUT_*
    case sequence = 8              // u64: results encoded in this generation (latest state; gaps are harmless)
    case tick = 9                  // u64: analysis ticks in this generation, the one this state closes
    case tickRate = 10             // f64: ticks per second of audio (60)
    case timelineEnd = 11          // u64: plugin stream position just after the newest frame analysed
    case framesAnalysed = 12       // u64: frames analysed in this generation
    case measurement = 13          // u32: MeasurementState
    case stateFlags = 14           // u32: ResultFlags
    case breaks = 15               // u32: breaks in the analysed audio in this generation
    case missingSeconds = 16       // f64: audio known missing at those breaks
    case lastBreakReasons = 17     // u32: ABR_AUDIO_AFTER_* of the newest break
    // Levels, per channel (linear)
    case peak = 20, rms = 21, truePeak = 22, heldPeak = 23, heldTruePeak = 24
    // Loudness (LUFS; LU for the range)
    case momentary = 30, shortTerm = 31, integrated = 32, loudnessRange = 33
    // Spectrum and stereo image
    case spectrum = 40             // f32[64]: dBFS per display band, L and R combined
    case dominant = 41             // f32[2]: dominant peak frequency (Hz) and level (dBFS)
    case notes = 42                // f32[12]: up to six (frequency Hz, level dBFS) pairs; frequency 0 = none
    case correlation = 43          // f32: −1…1, or −2 when there is no correlation to show
    case bandCorrelation = 44      // f32[9]: per band group (five bands, three, overall), −2 = none
    case bandWidth = 45, bandBalance = 46, bandLevel = 47   // f32[9] each
    case bandPoints = 48           // f32[1280]: per stereo band, 128 (L, R) stereometer points
    case bandPower = 49            // f32[channels × 5]: each channel's mean square per stereo band
    case detectedFormat = 50       // u32: 0 stereo, 1 spatial, 2 mono
    case spectrumFine = 51         // f32[128]: dBFS per fine band (each `spectrum` band halved), from the same transform
    // Ordered visual updates: the spectrogram and the waveform
    case spectrogramFirst = 60     // u64: serial of the first column carried (serials start at 1 per generation)
    case spectrogramRows = 61      // u32: values per column (512)
    case spectrogram = 62          // f32[n × rows]: n columns, oldest first, dBFS
    case spectrogramLatest = 63    // u64: newest column serial analysed (≥ first + n − 1)
    case spectrogramDropped = 64   // u64: columns skipped just before `first` because the receiver fell more than
                                   // the plugin's queue (about 2 s) behind; 0 when contiguous or for a new receiver
    case spectrogramMode = 65      // u32: analysis of the newest columns (`SpectrogramMode`: 0 Classic, 1 Enhanced;
                                   // build 72 and later, absent before: Classic)
    case waveformFirst = 70        // u64
    case waveformColumnRate = 71   // f64: columns per second of audio (240)
    case waveform = 72             // f32[n × channels × 2]: n columns, oldest first, (min, max) per channel
    case waveformLatest = 73       // u64
    case waveformDropped = 74      // u64: likewise
    // Configuration needed to interpret the results
    case fftSize = 80              // u32
    case spectrumBands = 81        // u32
    case correlationTime = 82      // f32: seconds
    case levelWindow = 83          // f32: seconds of audio that peak and RMS cover
}

/// RESULT state flags.
package enum ResultFlags {
    /// Published without new audio: nothing arrived for at least a tick (the host stopped processing).
    package static let idle: UInt32 = 1 << 0
}

/// Measurement state (the same values as ABR_MEASUREMENT_* in BridgeProtocol.h).
package enum MeasurementState: UInt32 {
    case none = 0        // no analysis yet: no usable format
    case measuring = 1
    case paused = 2      // measurement paused by a command: audio passes and is not accumulated
}

/// A decoded RESULT. Absent fields keep their defaults; `valid` says whether the fields every result must carry
/// are there and consistent.
package struct ResultMessage {
    package static let spectrogramRows = MeterSnapshot.spectrogramBandCount
    package var subscription: UInt32 = 0
    package var schema: UInt32 = 0
    package var generation: UInt32 = 0
    package var formatEpoch: UInt32 = 0
    package var sampleRate: Double = 0
    package var channels = 0
    package var layout: UInt32 = 0
    package var sequence: UInt64 = 0
    package var tick: UInt64 = 0
    package var tickRate: Double = 60
    package var timelineEnd: UInt64 = 0
    package var framesAnalysed: UInt64 = 0
    package var measurement = MeasurementState.none
    package var flags: UInt32 = 0
    package var breaks: UInt32 = 0
    package var missingSeconds: Double = 0
    package var lastBreakReasons: UInt32 = 0
    package var peak: [Float] = [], rms: [Float] = [], truePeak: [Float] = []
    package var heldPeak: [Float] = [], heldTruePeak: [Float] = []
    package var momentary: Float = -100, shortTerm: Float = -100, integrated: Float = -100, loudnessRange: Float = -1
    package var spectrum: [Float] = []
    package var spectrumFine: [Float] = []
    package var dominant: [Float] = []
    package var notes: [Float] = []
    package var correlation: Float = MeterSnapshot.noCorrelation
    package var bandCorrelation: [Float] = [], bandWidth: [Float] = [], bandBalance: [Float] = [], bandLevel: [Float] = []
    package var bandPoints: [Float] = []
    package var bandPower: [Float] = []
    package var detectedFormat: UInt32 = 0
    package var spectrogramFirst: UInt64 = 0
    package var spectrogramRows = ResultMessage.spectrogramRows
    package var spectrogram: [Float] = []
    package var spectrogramLatest: UInt64 = 0
    /// nil from a plugin that does not say (before build 72): its columns are Classic.
    package var spectrogramMode: UInt32?
    package var spectrogramDropped: UInt64 = 0
    package var waveformFirst: UInt64 = 0
    package var waveformColumnRate: Double = WaveformEnvelope.columnRate
    package var waveform: [Float] = []
    package var waveformLatest: UInt64 = 0
    package var waveformDropped: UInt64 = 0
    package var fftSize: UInt32 = 0
    package var spectrumBands: UInt32 = 0
    package var correlationTime: Float = 0
    package var levelWindow: Float = 0
    /// Known fields ignored for the wrong kind or size (unknown tags are skipped silently).
    package var rejectedFields = 0
    package var malformed = false

    package init() {}

    package var spectrogramColumns: Int { spectrogramRows > 0 ? spectrogram.count / spectrogramRows : 0 }
    package var waveformColumns: Int { channels > 0 ? waveform.count / (channels * 2) : 0 }

    /// Carries what every result must, within the protocol's limits: a schema this code reads, a generation, a
    /// real rate, 1–2 channels, per-channel levels of that many channels, and whole columns.
    package var valid: Bool {
        schema == StreamAnalyzer.schemaVersion && generation != 0 && sampleRate >= 8_000 && sampleRate <= 384_000
            && (1...2).contains(channels) && [peak, rms, truePeak, heldPeak, heldTruePeak].allSatisfy { $0.count == channels }
            && spectrogram.count == spectrogramColumns * spectrogramRows && waveform.count == waveformColumns * channels * 2
            && !malformed
    }

    package static func decode(_ payload: UnsafeRawBufferPointer) -> ResultMessage {
        var m = ResultMessage()
        var reader = WireReader(payload)
        let perChannel = 2
        let groups = StereoBands.groups.count
        func take<T>(_ value: T?, _ assign: (T) -> Void) {
            if let value { assign(value) } else { m.rejectedFields += 1 }
        }
        while let field = reader.next() {
            guard let tag = ResultTag(rawValue: field.tag) else { continue }
            switch tag {
            case .subscription: take(field.u32) { m.subscription = $0 }
            case .schema: take(field.u32) { m.schema = $0 }
            case .generation: take(field.u32) { m.generation = $0 }
            case .formatEpoch: take(field.u32) { m.formatEpoch = $0 }
            case .sampleRate: take(field.f64) { m.sampleRate = $0 }
            case .channels: take(field.u32) { m.channels = Int(min($0, 64)) }
            case .layout: take(field.u32) { m.layout = $0 }
            case .sequence: take(field.u64) { m.sequence = $0 }
            case .tick: take(field.u64) { m.tick = $0 }
            case .tickRate: take(field.f64) { m.tickRate = $0 }
            case .timelineEnd: take(field.u64) { m.timelineEnd = $0 }
            case .framesAnalysed: take(field.u64) { m.framesAnalysed = $0 }
            case .measurement: take(field.u32.flatMap(MeasurementState.init(rawValue:))) { m.measurement = $0 }
            case .stateFlags: take(field.u32) { m.flags = $0 }
            case .breaks: take(field.u32) { m.breaks = $0 }
            case .missingSeconds: take(field.f64) { m.missingSeconds = $0 }
            case .lastBreakReasons: take(field.u32) { m.lastBreakReasons = $0 }
            case .peak: take(field.f32s(limit: perChannel)) { m.peak = $0 }
            case .rms: take(field.f32s(limit: perChannel)) { m.rms = $0 }
            case .truePeak: take(field.f32s(limit: perChannel)) { m.truePeak = $0 }
            case .heldPeak: take(field.f32s(limit: perChannel)) { m.heldPeak = $0 }
            case .heldTruePeak: take(field.f32s(limit: perChannel)) { m.heldTruePeak = $0 }
            case .momentary: take(field.f32) { m.momentary = $0 }
            case .shortTerm: take(field.f32) { m.shortTerm = $0 }
            case .integrated: take(field.f32) { m.integrated = $0 }
            case .loudnessRange: take(field.f32) { m.loudnessRange = $0 }
            case .spectrum: take(field.f32s(limit: MeterSnapshot.bandCount)) { m.spectrum = $0 }
            case .spectrumFine: take(field.f32s(limit: MeterSnapshot.fineBandCount)) { m.spectrumFine = $0 }
            case .dominant: take(field.f32s(limit: 2)) { m.dominant = $0 }
            case .notes: take(field.f32s(limit: 2 * SpectrumAnalyzer.maxNotes)) { m.notes = $0 }
            case .correlation: take(field.f32) { m.correlation = $0 }
            case .bandCorrelation: take(field.f32s(limit: groups)) { m.bandCorrelation = $0 }
            case .bandWidth: take(field.f32s(limit: groups)) { m.bandWidth = $0 }
            case .bandBalance: take(field.f32s(limit: groups)) { m.bandBalance = $0 }
            case .bandLevel: take(field.f32s(limit: groups)) { m.bandLevel = $0 }
            case .bandPoints: take(field.f32s(limit: StereoBands.scopeFloats)) { m.bandPoints = $0 }
            case .bandPower: take(field.f32s(limit: perChannel * StereoBands.count)) { m.bandPower = $0 }
            case .detectedFormat: take(field.u32) { m.detectedFormat = $0 }
            case .spectrogramFirst: take(field.u64) { m.spectrogramFirst = $0 }
            case .spectrogramRows:
                take(field.u32.flatMap { $0 == UInt32(spectrogramRows) ? Int($0) : nil }) { m.spectrogramRows = $0 }
            case .spectrogram:
                take(field.f32s(limit: StreamAnalyzer.spectrogramCapacity * spectrogramRows)) { m.spectrogram = $0 }
            case .spectrogramLatest: take(field.u64) { m.spectrogramLatest = $0 }
            case .spectrogramMode: take(field.u32) { m.spectrogramMode = $0 }
            case .spectrogramDropped: take(field.u64) { m.spectrogramDropped = $0 }
            case .waveformFirst: take(field.u64) { m.waveformFirst = $0 }
            case .waveformColumnRate: take(field.f64) { m.waveformColumnRate = $0 }
            case .waveform: take(field.f32s(limit: StreamAnalyzer.waveformCapacity * perChannel * 2)) { m.waveform = $0 }
            case .waveformLatest: take(field.u64) { m.waveformLatest = $0 }
            case .waveformDropped: take(field.u64) { m.waveformDropped = $0 }
            case .fftSize: take(field.u32) { m.fftSize = $0 }
            case .spectrumBands: take(field.u32) { m.spectrumBands = $0 }
            case .correlationTime: take(field.f32) { m.correlationTime = $0 }
            case .levelWindow: take(field.f32) { m.levelWindow = $0 }
            }
        }
        m.malformed = reader.malformed
        return m
    }
}
