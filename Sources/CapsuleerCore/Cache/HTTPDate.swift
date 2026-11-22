import Foundation

/// Parses and formats HTTP dates (RFC 9110 §5.6.7): the preferred IMF-fixdate (RFC 1123),
/// plus the obsolete RFC 850 and asctime forms. Implemented by hand so it is allocation-light,
/// locale-independent and needs no shared `DateFormatter`.
enum HTTPDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let zones: Set<String> = ["gmt", "utc", "ut", "z", "+0000", "0000"]

    /// Parses `Sun, 06 Nov 1994 08:49:37 GMT`, `Sunday, 06-Nov-94 08:49:37 GMT` or
    /// `Sun Nov  6 08:49:37 1994`. Returns nil for anything else.
    static func parse(_ string: String) -> Date? {
        var tokens = string
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "-" || $0 == "\t" })
            .map { $0.lowercased() }
        guard !tokens.isEmpty else { return nil }
        if month(tokens[0]) == nil, tokens[0].allSatisfy(\.isLetter) { tokens.removeFirst() }  // weekday

        let day: Int, monthIndex: Int, yearToken: String, timeToken: String
        if tokens.count == 4, let m = month(tokens[0]) {
            // asctime: Nov 6 08:49:37 1994
            guard let d = Int(tokens[1]) else { return nil }
            day = d; monthIndex = m; timeToken = tokens[2]; yearToken = tokens[3]
        } else if tokens.count == 4 || tokens.count == 5 {
            // RFC 1123 / RFC 850: 06 Nov 1994 08:49:37 GMT
            guard let d = Int(tokens[0]), let m = month(tokens[1]) else { return nil }
            if tokens.count == 5, !zones.contains(tokens[4]) { return nil }
            day = d; monthIndex = m; yearToken = tokens[2]; timeToken = tokens[3]
        } else {
            return nil
        }

        guard var year = Int(yearToken), yearToken.allSatisfy(\.isNumber) else { return nil }
        if yearToken.count == 2 { year += year < 70 ? 2000 : 1900 } else if yearToken.count != 4 { return nil }

        let time = timeToken.split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 3, let hour = Int(time[0]), let minute = Int(time[1]), let second = Int(time[2]),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second),
              (1...daysInMonth(monthIndex + 1, year: year)).contains(day)
        else { return nil }

        let days = daysFromCivil(year: year, month: monthIndex + 1, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Formats as IMF-fixdate, e.g. `Sun, 06 Nov 1994 08:49:37 GMT`.
    static func format(_ date: Date) -> String {
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        var days = total / 86_400
        var secs = total % 86_400
        if secs < 0 { secs += 86_400; days -= 1 }
        let (y, m, d) = civilFromDays(days)
        let weekday = ((days % 7) + 7 + 4) % 7  // 1970-01-01 was a Thursday
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(weekdayNames[weekday]), \(two(d)) \(monthNames[m - 1]) \(y) \(two(secs / 3600)):\(two(secs / 60 % 60)):\(two(secs % 60)) GMT"
    }

    private static func month(_ token: String) -> Int? { months.firstIndex(of: token) }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // Howard Hinnant's civil-date algorithms (proleptic Gregorian calendar).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
