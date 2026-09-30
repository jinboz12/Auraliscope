import Foundation

/// Turns analysis results received from elsewhere (an Auraliscope Bridge insert) back into the snapshots the
/// displays read — the same `SnapshotSlots` layout the local pipeline publishes — at the display's own pace. It
/// holds only what a display needs: the newest state, the waveform window, and a short queue of spectrogram
/// columns. It never analyses audio. Not thread-safe: the owner serialises `receive` and `publish`.
///
/// - Latest state (levels, loudness, spectrum, stereo image) replaces whatever came before.
/// - Spectrogram columns are ordered: at most one reaches the display per tick (the display appends one column
///   per serial it sees), and a queue that grows past `spectrogramLag` columns skips ahead, so the waterfall is never
///   more than about a quarter of a second behind. Columns the sender dropped, or that were skipped, leave a blank
///   column each (up to `maxBlankColumns`), so the waterfall's time axis stays honest.
/// - Waveform columns are ordered and all reach the display (the snapshot's 64-column window carries up to 64 per
///   tick; `waveformPerTick` paces a catch-up). A gap leaves a flat notch, as a break does.
/// - A new generation (a reset, a format change) or another source is a new stream: the displays clear their
///   histories, as they do when local capture restarts.
package final class ResultAssembler {
    package static let spectrogramLag = 8
    package static let maxBlankColumns = 30
    package static let waveformPerTick = WaveformEnvelope.publishedColumns

    package private(set) var values = [Float](repeating: 0, count: SnapshotSlots.total)
    package private(set) var latest: ResultMessage?
    /// Identifies the stream the displays show: a new value per (source, generation).
    package private(set) var streamID: UInt32 = 0
    private var streamKey: (source: Int, generation: UInt32)?
    private var sequence = 0
    private var spectrogramSerial = 0
    private var spectrogramQueue: [[Float]] = []
    private var lastSpectrogram: UInt64 = 0
    private var waveformQueue: [[Float]] = []   // per column: (min, max) per channel
    private var lastWaveform: UInt64 = 0
    private var waveSerial = 0
    private var waveWindow = [Float](repeating: 0, count: WaveformEnvelope.publishedFloats)
    private var pendingState = false
    /// Counters for diagnostics and tests.
    package private(set) var received = 0
    package private(set) var rejected = 0
    package private(set) var spectrogramGaps: UInt64 = 0
    package private(set) var spectrogramSkipped: UInt64 = 0
    package private(set) var waveformGaps: UInt64 = 0

    package init(streamSeed: UInt32 = 0) { streamID = streamSeed }

    /// Takes one result of source `source` (any number the owner uses to tell sources apart). Returns false when
    /// it was not usable (malformed, another schema, inconsistent sizes).
    @discardableResult
    package func receive(_ message: ResultMessage, source: Int) -> Bool {
        guard message.valid else {
            rejected += 1
            return false
        }
        received += 1
        if streamKey?.source != source || streamKey?.generation != message.generation {
            // A new stream: nothing of the previous one continues.
            streamKey = (source, message.generation)
            streamID = streamID % 999_999 + 1
            spectrogramQueue.removeAll()
            waveformQueue.removeAll()
            lastSpectrogram = 0
            lastWaveform = 0
            spectrogramSerial = 0
            waveSerial = 0
            for i in waveWindow.indices { waveWindow[i] = 0 }
            values = [Float](repeating: 0, count: SnapshotSlots.total)
        }
        // Spectrogram: columns after the newest one taken, oldest first; a gap before them leaves blank columns.
        let rows = message.spectrogramRows
        for i in 0..<message.spectrogramColumns {
            let serial = message.spectrogramFirst + UInt64(i)
            guard serial > lastSpectrogram else { continue }
            if lastSpectrogram > 0 && serial > lastSpectrogram + 1 {
                let missing = serial - lastSpectrogram - 1
                spectrogramGaps += missing
                for _ in 0..<min(missing, UInt64(Self.maxBlankColumns)) {
                    spectrogramQueue.append([Float](repeating: -120, count: rows))
                }
            }
            spectrogramQueue.append(Array(message.spectrogram[(i * rows)..<((i + 1) * rows)]))
            lastSpectrogram = serial
        }
        // Waveform: likewise, with a flat notch for a gap.
        let stride = message.channels * 2
        for i in 0..<message.waveformColumns {
            let serial = message.waveformFirst + UInt64(i)
            guard serial > lastWaveform else { continue }
            if lastWaveform > 0 && serial > lastWaveform + 1 {
                let missing = serial - lastWaveform - 1
                waveformGaps += missing
                for _ in 0..<min(missing, UInt64(WaveformEnvelope.notchColumns.upperBound)) {
                    waveformQueue.append([Float](repeating: 0, count: stride))
                }
            }
            waveformQueue.append(Array(message.waveform[(i * stride)..<((i + 1) * stride)]))
            lastWaveform = serial
        }
        latest = message
        pendingState = true
        return true
    }

    /// Whether a result arrived that no snapshot has shown yet, or columns are still waiting.
    package var hasPending: Bool { pendingState || !spectrogramQueue.isEmpty || !waveformQueue.isEmpty }

    /// Writes the next snapshot for the displays, if there is anything new. Returns whether it did.
    @discardableResult
    package func publish() -> Bool {
        guard let m = latest, hasPending else { return false }
        pendingState = false
        let roles = m.channels == 1 ? [Role.left] : [Role.left, Role.right]
        func perChannel(_ slot: Int, _ source: [Float]) {
            for role in 0..<Role.count { values[slot + role] = 0 }
            for (channel, role) in roles.enumerated() where channel < source.count { values[slot + role] = source[channel] }
        }
        perChannel(SnapshotSlots.peaks, m.peak)
        perChannel(SnapshotSlots.rms, m.rms)
        perChannel(SnapshotSlots.truePeaks, m.truePeak)
        perChannel(SnapshotSlots.heldPeaks, m.heldPeak)
        perChannel(SnapshotSlots.heldTruePeaks, m.heldTruePeak)
        values[SnapshotSlots.momentary] = m.momentary
        values[SnapshotSlots.shortTerm] = m.shortTerm
        values[SnapshotSlots.integrated] = m.integrated
        values[SnapshotSlots.range] = m.loudnessRange
        copy(m.spectrum, to: SnapshotSlots.spectrum, count: MeterSnapshot.bandCount, fill: -120)
        values[SnapshotSlots.peakFrequency] = m.dominant.count == 2 ? m.dominant[0] : 0
        values[SnapshotSlots.peakLevel] = m.dominant.count == 2 ? m.dominant[1] : -120
        for i in 0..<(2 * SpectrumAnalyzer.maxNotes) {
            values[SnapshotSlots.notes + i] = i < m.notes.count ? m.notes[i] : (i.isMultiple(of: 2) ? 0 : -120)
        }
        values[SnapshotSlots.correlation] = m.correlation
        let groups = StereoBands.groups.count
        copy(m.bandCorrelation, to: SnapshotSlots.bandCorrelation, count: groups, fill: MeterSnapshot.noCorrelation)
        copy(m.bandWidth, to: SnapshotSlots.bandWidth, count: groups, fill: 0)
        copy(m.bandBalance, to: SnapshotSlots.bandBalance, count: groups, fill: 0)
        copy(m.bandLevel, to: SnapshotSlots.bandLevel, count: groups, fill: -120)
        copy(m.bandPoints, to: SnapshotSlots.bandPoints, count: StereoBands.scopeFloats, fill: 0)
        for i in 0..<StereoBands.roleFloats { values[SnapshotSlots.roleBandPower + i] = 0 }
        for (channel, role) in roles.enumerated() {
            for band in 0..<StereoBands.count where channel * StereoBands.count + band < m.bandPower.count {
                values[SnapshotSlots.roleBandPower + role * StereoBands.count + band] = m.bandPower[channel * StereoBands.count + band]
            }
        }
        // Mono or stereo: the Stereo ↔ Spatial detector has nothing to decide.
        values[SnapshotSlots.format] = Float(ChannelFormat.stereo.rawValue)
        values[SnapshotSlots.breaks] = Float(m.breaks)
        values[SnapshotSlots.missing] = Float(m.missingSeconds)

        // One spectrogram column per tick; a backlog beyond `spectrogramLag` is skipped, newest kept.
        if spectrogramQueue.count > Self.spectrogramLag {
            let skip = spectrogramQueue.count - Self.spectrogramLag
            spectrogramSkipped += UInt64(skip)
            spectrogramQueue.removeFirst(skip)
        }
        if !spectrogramQueue.isEmpty {
            let column = spectrogramQueue.removeFirst()
            copy(column, to: SnapshotSlots.spectrogram, count: MeterSnapshot.spectrogramBandCount, fill: -120)
            spectrogramSerial = spectrogramSerial % 999_999 + 1
        }
        values[SnapshotSlots.spectrogramSerial] = Float(spectrogramSerial)

        // Waveform: new columns enter the 64-column window, oldest first.
        let take = min(waveformQueue.count, Self.waveformPerTick)
        if take > 0 {
            let per = WaveformEnvelope.valuesPerColumn
            let keep = WaveformEnvelope.publishedColumns - take
            waveWindow.replaceSubrange(0..<(keep * per), with: waveWindow[(take * per)...])
            for (index, column) in waveformQueue.prefix(take).enumerated() {
                let base = (keep + index) * per
                for i in 0..<per { waveWindow[base + i] = 0 }
                for (channel, role) in roles.enumerated() where channel * 2 + 1 < column.count {
                    waveWindow[base + role * 2] = column[channel * 2]
                    waveWindow[base + role * 2 + 1] = column[channel * 2 + 1]
                }
            }
            waveformQueue.removeFirst(take)
            waveSerial = (waveSerial + take) % WaveformEnvelope.serialModulus
        }
        copy(waveWindow, to: SnapshotSlots.waveform, count: WaveformEnvelope.publishedFloats, fill: 0)
        values[SnapshotSlots.waveSerial] = Float(waveSerial)

        sequence = sequence % 999_999 + 1
        values[SnapshotSlots.sequence] = Float(sequence)
        values[SnapshotSlots.stream] = Float(streamID)
        return true
    }

    /// The source stopped sending (disconnected, or the host stopped processing without the plugin saying so):
    /// the instantaneous readings fall to silence; what was measured (loudness, held peaks, histories) stays.
    package func silenceTransients() {
        guard var m = latest else { return }
        let silence = [Float](repeating: 0, count: m.channels)
        m.peak = silence
        m.rms = silence
        m.truePeak = silence
        m.spectrum = [Float](repeating: -120, count: MeterSnapshot.bandCount)
        m.dominant = [0, -120]
        m.notes = []
        m.correlation = MeterSnapshot.noCorrelation
        m.bandCorrelation = [Float](repeating: MeterSnapshot.noCorrelation, count: StereoBands.groups.count)
        m.bandLevel = [Float](repeating: -120, count: StereoBands.groups.count)
        m.bandPoints = [Float](repeating: 0, count: StereoBands.scopeFloats)
        m.bandPower = [Float](repeating: 0, count: m.channels * StereoBands.count)
        latest = m
        pendingState = true
    }

    private func copy(_ source: [Float], to slot: Int, count: Int, fill: Float) {
        for i in 0..<count { values[slot + i] = i < source.count ? source[i] : fill }
    }
}
