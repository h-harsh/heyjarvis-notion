import Foundation
import ScrollbackCore

/// Throwaway spike store: append-only JSONL, one line per episode open/close
/// and per capture event, rotated per local day. Human-inspectable for
/// dogfooding capture quality. Replaced by the encrypted SQLCipher store (M1
/// store tasks) before real dogfood history accumulates — do not build on this.
final class JSONLSink: CaptureEventSink {

    private let directory: URL
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var currentDay: String = ""
    private(set) var path: String = ""
    private var warnedOnce = false

    private struct EpisodeLine: Encodable {
        let kind: String
        let episode: Episode
    }

    private struct EventLine: Encodable {
        let kind = "event"
        let event: CaptureEvent
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try rotateIfNeeded()
    }

    /// Local-day stamp (YYYY-MM-DD). Recomputed per write so a daemon running
    /// past midnight rolls to a new file instead of appending forever.
    private func dayStamp() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func rotateIfNeeded() throws {
        let day = dayStamp()
        guard day != currentDay else { return }
        try? handle?.close()
        currentDay = day
        let fileURL = directory.appendingPathComponent("capture-\(day).jsonl")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        path = fileURL.path
        handle = try FileHandle(forWritingTo: fileURL)
        try handle?.seekToEnd()
    }

    func episodeOpened(_ episode: Episode) {
        write(EpisodeLine(kind: "episode_open", episode: episode))
    }

    func episodeClosed(_ episode: Episode) {
        write(EpisodeLine(kind: "episode_close", episode: episode))
    }

    func event(_ event: CaptureEvent) {
        write(EventLine(event: event))
    }

    private func write<T: Encodable>(_ line: T) {
        do {
            try rotateIfNeeded()
            var data = try encoder.encode(line)
            data.append(0x0A) // newline
            try handle?.write(contentsOf: data)
        } catch {
            if !warnedOnce {
                warnedOnce = true
                FileHandle.standardError.write(Data("scrollbackd: JSONL write failed: \(error)\n".utf8))
            }
        }
    }
}
