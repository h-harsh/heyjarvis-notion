import Foundation

/// Extracts the EVENT time a chunk refers to (`chunks.ts_event`), distinct from
/// when the text was captured (`ts_capture`). "Let's move standup to Friday"
/// captured on a Monday should be retrievable by BOTH Monday (capture) and that
/// Friday (event) — the dual-timestamp requirement.
///
/// Pure + deterministic given `capturedAt` and the injected calendar/timezone. It
/// resolves relative expressions ("tomorrow", "Friday", "next week") against the
/// CAPTURE time — not wall-clock now. (`NSDataDetector` resolves relative dates
/// against the current date, which is both wrong here and non-deterministic, so we
/// resolve a curated pattern set ourselves.)
///
/// Precision over recall, like the redactor: only high-confidence date shapes fire.
/// A missed date is better than a wrong `ts_event` polluting time-filtered recall.
/// The FIRST recognizable reference in reading order wins (a chunk stores one event
/// time; multi-date chunks are a future `event_times` enhancement).
public struct EventTimeExtractor: Sendable {
    private let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// The event time referenced in `text`, resolved relative to `capturedAt`, or
    /// nil if no high-confidence date/time reference is present.
    public func eventTime(in text: String, capturedAt: Date) -> Date? {
        candidates(in: text, capturedAt: capturedAt)
            .min { ($0.location, $0.priority) < ($1.location, $1.priority) }?
            .date
    }

    // MARK: - Match collection

    private struct Candidate { let location: Int; let priority: Int; let date: Date }

    private func candidates(in text: String, capturedAt: Date) -> [Candidate] {
        let ns = text as NSString
        var out: [Candidate] = []

        // Priority 0 (absolute) → 3 (most relative). On a location tie, the more
        // absolute reference wins.
        if let m = Self.isoDate.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let year = int(m, 1, ns), let month = int(m, 2, ns), let day = int(m, 3, ns),
           let date = makeDate(year: year, month: month, day: day) {
            out.append(Candidate(location: m.range.location, priority: 0, date: date))
        }

        if let c = monthNameCandidate(Self.monthThenDay, monthGroup: 1, dayGroup: 2, yearGroup: 3, ns: ns, capturedAt: capturedAt) {
            out.append(c)
        }
        if let c = monthNameCandidate(Self.dayThenMonth, monthGroup: 2, dayGroup: 1, yearGroup: 3, ns: ns, capturedAt: capturedAt) {
            out.append(c)
        }

        if let m = Self.relativeDay.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let word = string(m, 1, ns)?.lowercased() {
            let delta = (word == "yesterday") ? -1 : (word == "today" ? 0 : 1) // tomorrow/tmrw → +1
            if let date = calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: capturedAt)) {
                out.append(Candidate(location: m.range.location, priority: 2, date: date))
            }
        }

        if let m = Self.weekday.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           let name = string(m, 2, ns)?.lowercased(), let targetWD = Self.weekdays[name] {
            let qualifier = string(m, 1, ns)?.lowercased()
            if let date = resolveWeekday(targetWD, qualifier: qualifier, capturedAt: capturedAt) {
                out.append(Candidate(location: m.range.location, priority: 3, date: date))
            }
        }

        return out
    }

    private func monthNameCandidate(
        _ regex: NSRegularExpression, monthGroup: Int, dayGroup: Int, yearGroup: Int,
        ns: NSString, capturedAt: Date
    ) -> Candidate? {
        guard let m = regex.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)),
              let monthWord = string(m, monthGroup, ns)?.lowercased().replacingOccurrences(of: ".", with: ""),
              let month = Self.months[monthWord],
              let day = int(m, dayGroup, ns) else { return nil }

        if let year = int(m, yearGroup, ns) {
            guard let date = makeDate(year: year, month: month, day: day) else { return nil }
            return Candidate(location: m.range.location, priority: 1, date: date)
        }
        // No year → future-leaning: this year, rolling to next if already past the
        // capture day (an undated "meeting on Jan 3" read in December means next Jan).
        let capYear = calendar.component(.year, from: capturedAt)
        guard let thisYear = makeDate(year: capYear, month: month, day: day) else { return nil }
        let resolved = thisYear < calendar.startOfDay(for: capturedAt)
            ? makeDate(year: capYear + 1, month: month, day: day)
            : thisYear
        guard let date = resolved else { return nil }
        return Candidate(location: m.range.location, priority: 1, date: date)
    }

    // MARK: - Resolution

    /// A calendar date at local midnight, rejecting overflowed inputs (month 13,
    /// day 32, Feb 30, …) via a round-trip component check.
    private func makeDate(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    /// Resolve a weekday relative to the capture day.
    /// - bare / `this` / `coming`: soonest occurrence ≥ capture day (today if it matches).
    /// - `next`: that occurrence + 7 (next week's).
    /// - `last`: that occurrence − 7 (the most recent past one).
    private func resolveWeekday(_ targetWD: Int, qualifier: String?, capturedAt: Date) -> Date? {
        let capDay = calendar.startOfDay(for: capturedAt)
        let capWD = calendar.component(.weekday, from: capDay)
        var delta = (targetWD - capWD + 7) % 7 // 0…6, soonest occurrence on/after today
        switch qualifier {
        case "next": delta = delta == 0 ? 7 : delta + 7
        case "last": delta -= 7
        default: break // nil / "this" / "coming"
        }
        return calendar.date(byAdding: .day, value: delta, to: capDay)
    }

    // MARK: - Group helpers

    private func string(_ match: NSTextCheckingResult, _ index: Int, _ ns: NSString) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    private func int(_ match: NSTextCheckingResult, _ index: Int, _ ns: NSString) -> Int? {
        string(match, index, ns).flatMap { Int($0) }
    }

    // MARK: - Patterns (compiled once; literals, so force-compiled)

    private static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
        "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]
    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]
    private static let monthAlt =
        "jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december"

    private static func compile(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let isoDate = compile(#"\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b"#)
    private static let monthThenDay = compile(#"\b("# + monthAlt + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#)
    private static let dayThenMonth = compile(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+("# + monthAlt + #")\.?(?:,?\s+(\d{4}))?\b"#)
    private static let relativeDay = compile(#"\b(today|tomorrow|tmrw|yesterday)\b"#)
    private static let weekday = compile(#"\b(next|this|last|coming)?\s*(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#)
}

private extension NSRegularExpression {
    func firstMatch(in text: String, range: NSRange) -> NSTextCheckingResult? {
        firstMatch(in: text, options: [], range: range)
    }
}
