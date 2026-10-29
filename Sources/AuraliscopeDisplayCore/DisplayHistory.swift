import Foundation

/// The waterfall's history: spectrogram columns in serial order, `capacity` newest kept. Columns the sender skipped
/// (a gap in the serials, or its `dropped` count) leave blank columns, at most `maxBlank`, so the time axis stays
/// honest; a new stream (another source, generation or format) starts empty, so nothing of one source is ever drawn
/// as part of another.
public struct SpectrogramHistory: Sendable {
    public static let silence: Float = -120
    public static let maxBlank = 30
    public let capacity: Int
    public let rows: Int
    public private(set) var columns: [[Float]] = []
    public private(set) var lastSerial: UInt64 = 0
    public private(set) var streamKey: StreamKey?
    /// Bumped on every change, for views that redraw only when it moves.
    public private(set) var revision = 0
    public private(set) var gaps: UInt64 = 0

    public struct StreamKey: Hashable, Sendable {
        public var source: String
        public var generation: UInt32
        public var sampleRate: Double
        public var channels: Int
        public init(source: String, generation: UInt32, sampleRate: Double, channels: Int) {
            self.source = source
            self.generation = generation
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public init(capacity: Int = 600, rows: Int = AnalysisFrame.spectrogramRows) {
        self.capacity = capacity
        self.rows = rows
    }

    public mutating func reset() {
        columns.removeAll(keepingCapacity: true)
        lastSerial = 0
        streamKey = nil
        revision += 1
    }

    /// Adds the columns `frame` carries, for the stream `source` names.
    public mutating func append(_ frame: AnalysisFrame, source: String) {
        let key = StreamKey(source: source, generation: frame.generation, sampleRate: frame.sampleRate,
                            channels: frame.channels.count)
        if key != streamKey {
            reset()
            streamKey = key
        }
        guard !frame.spectrogramColumns.isEmpty else { return }
        var serial = frame.spectrogramFirst
        for column in frame.spectrogramColumns {
            defer { serial += 1 }
            guard column.count == rows, serial > lastSerial else { continue }   // never twice, never backwards
            if lastSerial != 0 && serial > lastSerial + 1 {
                let missing = serial - lastSerial - 1
                gaps += missing
                for _ in 0..<min(UInt64(Self.maxBlank), missing) { push([Float](repeating: Self.silence, count: rows)) }
            }
            push(column)
            lastSerial = serial
        }
        revision += 1
    }

    private mutating func push(_ column: [Float]) {
        columns.append(column)
        if columns.count > capacity { columns.removeFirst(columns.count - capacity) }
    }
}

/// How current a remote source's values are (Wireless Display), from what the connection last delivered.
public enum RemoteFreshness: Equatable, Sendable {
    /// Results are arriving.
    case live
    /// The plugin is connected and reporting, but its host is not delivering audio (stopped, bypassed, offline
    /// render): the values shown are the last measured, still the plugin's current state.
    case idle(String)
    /// Nothing has arrived for `seconds`: the values may no longer be the plugin's state.
    case stale(seconds: Double)
    case disconnected

    public static let resultWindow = 0.5
    public static let messageWindow = 1.0

    /// `sinceResult`/`sinceMessage`: seconds since the newest result and message (nil: none yet).
    public static func evaluate(connected: Bool, sinceResult: Double?, sinceMessage: Double?, status: BridgeStatus) -> RemoteFreshness {
        guard connected else { return .disconnected }
        guard let sinceMessage, sinceMessage <= messageWindow else { return .stale(seconds: sinceMessage ?? 0) }
        if let sinceResult, sinceResult <= resultWindow { return .live }
        switch BridgeState(rawValue: status.state) {
        case .bypassed: return .idle("Bypassed")
        case .offline: return .idle("Offline render")
        case .inactive: return .idle("Inactive")
        default:
            if status.measurement == 2 { return .idle("Paused") }
            return .idle("No audio from the host")
        }
    }

    public var label: String {
        switch self {
        case .live: return "Live"
        case .idle(let why): return why
        case .stale(let seconds): return String(format: "Stale · %.1f s", seconds)
        case .disconnected: return "Disconnected"
        }
    }

    /// Whether the values shown are dimmed as possibly out of date.
    public var dims: Bool {
        switch self {
        case .stale, .disconnected: return true
        default: return false
        }
    }
}
