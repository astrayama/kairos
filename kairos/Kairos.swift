import SwiftUI
import SwiftData
import Charts
import UserNotifications
import Combine

// MARK: - Design Tokens

extension Color {
    static let bgPrimary     = Color("BackgroundPrimary")
    static let bgCard        = Color("CardBackground")
    static let textPrimary   = Color("PrimaryText")
    static let textSecondary = Color("SecondaryText")
}

struct Theme {
    static let pink      = Color.accentPink
    static let lilac     = Color.accentLilac
    static let babyBlue  = Color.accentBlue
    static let navy      = Color.textPrimary
    static let darkPink  = Color.accentPink
    static let darkLilac = Color.accentLilac
    static let darkBlue  = Color.accentBlue
    static let teal      = Color.accentTeal
    static let gold      = Color.accentGold
    static let label          = Color.textPrimary
    static let secondaryLabel = Color.textSecondary
}

// MARK: - Enums

enum ReminderFrequency: String, CaseIterable {
    case off = "Off"; case threePerDay = "3 reminders per day"
    case sixPerDay = "6 reminders per day"; case hourly = "Hourly"
}

enum FilterType: Hashable {
    case activity(String), location(String), hashtag(String)
    var displayTitle: String {
        switch self {
        case .activity(let t): return "⚡ \(t)"
        case .location(let l): return "📍 \(l)"
        case .hashtag(let t):  return "#\(t)"
        }
    }
    var emptyStateMessage: String {
        switch self {
        case .activity(let t): return "No moments logged with activity \"\(t)\" yet."
        case .location(let l): return "No moments logged at \"\(l)\" yet."
        case .hashtag(let t):  return "No moments logged with #\(t) yet."
        }
    }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case week = "7 Days"; case month = "30 Days"; case all = "All Time"
    var id: String { rawValue }
    func startDate() -> Date? {
        switch self {
        case .week:  return Calendar.current.date(byAdding: .day, value: -7,  to: Date())
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .all:   return nil
        }
    }
}

// MARK: - Notification Manager

class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    let openCheckInPublisher = PassthroughSubject<Void, Never>()
    override init() { super.init(); UNUserNotificationCenter.current().delegate = self }
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func scheduleNotifications(frequency: ReminderFrequency, startHour: Int, endHour: Int) {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        guard frequency != .off, endHour > startHour else { return }
        let content = UNMutableNotificationContent()
        content.title = "Kairos"; content.body = "How are you right now?"; content.sound = .default
        var hours: [Int] = []
        switch frequency {
        case .hourly:      hours = Array(startHour...endHour)
        case .threePerDay: let s = Double(endHour - startHour) / 2; hours = [startHour, Int(Double(startHour) + s), endHour]
        case .sixPerDay:   let s = Double(endHour - startHour) / 5; hours = (0...5).map { Int(Double(startHour) + Double($0) * s) }
        case .off: break
        }
        for h in Set(hours) {
            var dc = DateComponents(); dc.hour = h; dc.minute = 0
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString + "-\(h)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
        }
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.openCheckInPublisher.send(()) }; done()
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// MARK: - App Entry Point

@main
struct KairosApp: App {
    init() { _ = NotificationManager.shared }
    var body: some Scene {
        WindowGroup { ContentView() }.modelContainer(for: CheckIn.self)
    }
}

// MARK: - Data Model

@Model final class CheckIn {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var mood: Double?; var energy: Double?; var bodyComfort: Double?
    var clarity: Double?; var socialBattery: Double?
    var activityTags: [String]; var location: String?
    var journalNote: String?; var hashtags: [String] = []

    init(id: UUID = UUID(), timestamp: Date = Date(),
         mood: Double? = nil, energy: Double? = nil, bodyComfort: Double? = nil,
         clarity: Double? = nil, socialBattery: Double? = nil,
         activityTags: [String] = [], location: String? = nil,
         journalNote: String? = nil, hashtags: [String] = []) {
        self.id = id; self.timestamp = timestamp
        self.mood = mood; self.energy = energy; self.bodyComfort = bodyComfort
        self.clarity = clarity; self.socialBattery = socialBattery
        self.activityTags = activityTags; self.location = location
        self.journalNote = journalNote
        self.hashtags = hashtags.isEmpty ? CheckIn.extractHashtags(from: journalNote) : hashtags
    }

    var overallAverage: Double? {
        let v = [mood, energy, bodyComfort, clarity, socialBattery].compactMap { $0 }
        guard !v.isEmpty else { return nil }; return v.reduce(0, +) / Double(v.count)
    }

    static func extractHashtags(from text: String?) -> [String] {
        guard let text else { return [] }
        var tags: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix("#") else { continue }
            var core = token.drop(while: { $0 == "#" })
            while let last = core.last, last.isPunctuation { core = core.dropLast() }
            let norm = String(core).lowercased()
            if !norm.isEmpty, !tags.contains(norm) { tags.append(norm) }
        }
        return tags
    }
}

// MARK: - Analytics Engine
// All heavy computation lives here. InsightsView passes its filtered array in;
// everything is a pure function/struct so it can be computed once per range change.

struct MetricStats {
    let metric: InsightMetric
    let avg: Double
    let min: Double; let minEntry: CheckIn
    let max: Double; let maxEntry: CheckIn
    let stdDev: Double
    let trendDirection: Double   // positive = improving, negative = declining
    let firstThirdAvg: Double
    let lastThirdAvg: Double
    let count: Int

    var trendObservation: String {
        let name = metric.rawValue.lowercased()
        var parts: [String] = []

        let fmtFirst = String(format: "%.1f", firstThirdAvg)
        let fmtLast  = String(format: "%.1f", lastThirdAvg)
        let fmtAvg   = String(format: "%.1f", avg)

        // Trend
        if trendDirection > 1.5 {
            parts.append("Your \(name) has been climbing noticeably — from around \(fmtFirst) to \(fmtLast) over this period.")
        } else if trendDirection > 0.5 {
            parts.append("Your \(name) has been gently improving lately.")
        } else if trendDirection < -1.5 {
            parts.append("Your \(name) has been lower toward the end of this period — from around \(fmtFirst) to \(fmtLast). That's worth noticing.")
        } else if trendDirection < -0.5 {
            parts.append("Your \(name) has dipped a little toward the end of this period.")
        } else {
            parts.append("Your \(name) has been fairly steady around \(fmtAvg).")
        }

        // Volatility
        if stdDev > 2.5 {
            parts.append("It's been quite variable — your \(name) shifted a lot day to day.")
        } else if stdDev > 1.5 {
            parts.append("There's been some variability here.")
        } else if stdDev < 0.7 {
            parts.append("Very consistent.")
        }

        return parts.joined(separator: " ")
    }

    static func compute(metric: InsightMetric, checkIns: [CheckIn]) -> MetricStats? {
        let pairs: [(Double, CheckIn)] = checkIns.compactMap {
            guard let v = $0[keyPath: metric.keyPath] else { return nil }
            return (v, $0)
        }.sorted { $0.1.timestamp < $1.1.timestamp }

        guard pairs.count >= 1,
              let minP = pairs.min(by: { $0.0 < $1.0 }),
              let maxP = pairs.max(by: { $0.0 < $1.0 }) else { return nil }

        let values = pairs.map(\.0)
        let avg    = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(values.count)
        let stdDev = sqrt(variance)

        // Trend: compare first-third avg to last-third avg
        var trendDirection: Double = 0
        var firstThirdAvg: Double = avg
        var lastThirdAvg: Double = avg
        
        if pairs.count >= 3 {
            let chunk = Swift.max(1, pairs.count / 3)
            firstThirdAvg = pairs.prefix(chunk).map(\.0).reduce(0, +) / Double(chunk)
            lastThirdAvg  = pairs.suffix(chunk).map(\.0).reduce(0, +) / Double(chunk)
            trendDirection = lastThirdAvg - firstThirdAvg
        }

        return MetricStats(metric: metric, avg: avg,
                           min: minP.0, minEntry: minP.1,
                           max: maxP.0, maxEntry: maxP.1,
                           stdDev: stdDev, trendDirection: trendDirection,
                           firstThirdAvg: firstThirdAvg, lastThirdAvg: lastThirdAvg,
                           count: pairs.count)
    }
}

struct CorrelationObservation {
    let text: String
    let strength: Double  // used for sorting (absolute value)
}

struct Analytics {

    // MARK: Pearson correlation (returns nil if < 3 data points or zero variance)
    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        let n = min(xs.count, ys.count)
        guard n >= 3 else { return nil }
        let mx = xs.reduce(0, +) / Double(n)
        let my = ys.reduce(0, +) / Double(n)
        let num = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let dx  = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        let dy  = ys.map { ($0 - my) * ($0 - my) }.reduce(0, +)
        guard dx > 0, dy > 0 else { return nil }
        return num / sqrt(dx * dy)
    }

    // MARK: Metric–metric correlations
    static func metricCorrelations(checkIns: [CheckIn]) -> [CorrelationObservation] {
        let pairs: [(InsightMetric, InsightMetric, String, String)] = [
            (.mood,    .energy,        "mood",           "energy"),
            (.mood,    .body,          "mood",           "body comfort"),
            (.clarity, .energy,        "clarity",        "energy"),
            (.social,  .mood,          "social battery", "mood"),
        ]

        var results: [CorrelationObservation] = []

        for (ma, mb, na, nb) in pairs {
            let combined: [(Double, Double)] = checkIns.compactMap {
                guard let a = $0[keyPath: ma.keyPath], let b = $0[keyPath: mb.keyPath] else { return nil }
                return (a, b)
            }
            guard combined.count >= 3 else { continue }
            let xs = combined.map(\.0)
            let ys = combined.map(\.1)
            let avgX = xs.reduce(0, +) / Double(xs.count)
            let avgY = ys.reduce(0, +) / Double(ys.count)

            // When X is high, what does Y average?
            let highX = combined.filter { $0.0 >= avgX }.map(\.1)
            let lowX  = combined.filter { $0.0 <  avgX }.map(\.1)
            guard !highX.isEmpty, !lowX.isEmpty else { continue }
            let avgYwhenXhi = highX.reduce(0, +) / Double(highX.count)
            let avgYwhenXlo = lowX.reduce(0,  +) / Double(lowX.count)
            let diff = avgYwhenXhi - avgYwhenXlo
            let absDiff = abs(diff)
            
            guard absDiff >= 0.8 else { continue }
            
            let fmtHi = String(format: "%.1f", avgYwhenXhi)
            let fmtLo = String(format: "%.1f", avgYwhenXlo)
            var text: String
            
            if diff > 0 {
                text = "Higher \(na) tends to go hand-in-hand with higher \(nb) (\(fmtHi) vs \(fmtLo) on average)."
            } else if absDiff >= 2.0 {
                text = "Interestingly, when your \(na) is high, your \(nb) tends to be lower (\(fmtHi) vs \(fmtLo))."
            } else {
                text = "When your \(na) is higher, your \(nb) is often slightly lower (\(fmtHi) vs \(fmtLo))."
            }
            results.append(CorrelationObservation(text: text, strength: absDiff))
        }

        return Array(results.sorted { $0.strength > $1.strength }.prefix(3))
    }

    // MARK: Tag frequency
    static func tagFrequency(checkIns: [CheckIn]) -> (activities: [(String, Int)], locations: [(String, Int)], hashtags: [(String, Int)]) {
        var actCounts: [String: Int] = [:]
        var locCounts: [String: Int] = [:]
        var hashCounts: [String: Int] = [:]

        for ci in checkIns {
            for t in ci.activityTags { actCounts[t, default: 0] += 1 }
            if let l = ci.location, !l.isEmpty { locCounts[l, default: 0] += 1 }
            for h in ci.hashtags { hashCounts[h, default: 0] += 1 }
        }

        let sorted: ([String: Int]) -> [(String, Int)] = {
            $0.sorted { $0.value > $1.value }
        }
        return (sorted(actCounts), sorted(locCounts), sorted(hashCounts))
    }

    // MARK: Tag–metric effects
    struct TagEffect {
        let tag: String
        let filterType: FilterType
        let metric: InsightMetric
        let avgWith: Double
        let avgWithout: Double
        var diff: Double { avgWith - avgWithout }

        var observation: String {
            let mag = abs(diff)
            let size = mag >= 2.0 ? "notably" : (mag >= 1.0 ? "a bit" : "slightly")
            let name = metric.rawValue.lowercased()
            let fmtWith = String(format: "%.1f", avgWith)
            let fmtWithout = String(format: "%.1f", avgWithout)
            
            switch filterType {
            case .activity(let t):
                if diff > 0 {
                    return "When you're \(t), your \(name) tends to be \(size) higher (\(fmtWith) vs \(fmtWithout) on other days)."
                } else {
                    return "When you're \(t), your \(name) tends to run \(size) lower (\(fmtWith) vs \(fmtWithout) on other days)."
                }
            case .location(let l):
                if diff > 0 {
                    return "At \(l), your \(name) tends to be \(size) higher (\(fmtWith) vs \(fmtWithout) elsewhere)."
                } else {
                    return "At \(l), your \(name) tends to run \(size) lower (\(fmtWith) vs \(fmtWithout) elsewhere)."
                }
            case .hashtag(let t):
                if diff > 0 {
                    return "On days you write #\(t), your \(name) is \(size) higher (\(fmtWith) vs \(fmtWithout) on other days)."
                } else {
                    return "On days you write #\(t), your \(name) tends to be \(size) lower (\(fmtWith) vs \(fmtWithout) on other days)."
                }
            }
        }
    }

    static func tagEffects(checkIns: [CheckIn], minOccurrences: Int = 3) -> [TagEffect] {
        var results: [TagEffect] = []
        let freq = tagFrequency(checkIns: checkIns)

        func process(tag: String, ft: FilterType, matches: @escaping (CheckIn) -> Bool) {
            let withTag    = checkIns.filter(matches)
            let withoutTag = checkIns.filter { !matches($0) }
            guard withTag.count >= minOccurrences else { return }

            for m in InsightMetric.allCases {
                let valsWith    = withTag.compactMap    { $0[keyPath: m.keyPath] }
                let valsWithout = withoutTag.compactMap { $0[keyPath: m.keyPath] }
                guard valsWith.count >= minOccurrences, !valsWithout.isEmpty else { continue }
                let avgWith    = valsWith.reduce(0, +)    / Double(valsWith.count)
                let avgWithout = valsWithout.reduce(0, +) / Double(valsWithout.count)
                guard abs(avgWith - avgWithout) >= 0.8 else { continue }
                results.append(TagEffect(tag: tag, filterType: ft, metric: m, avgWith: avgWith, avgWithout: avgWithout))
            }
        }

        for (tag, _) in freq.activities.prefix(10) {
            process(tag: tag, ft: .activity(tag)) { $0.activityTags.contains(tag) }
        }
        for (loc, _) in freq.locations.prefix(6) {
            let lc = loc.lowercased()
            process(tag: loc, ft: .location(loc)) { $0.location?.lowercased() == lc }
        }
        for (hash, _) in freq.hashtags.prefix(8) {
            process(tag: hash, ft: .hashtag(hash)) { $0.hashtags.contains(hash) }
        }

        // Pick the most striking effects (top 6 by absolute magnitude)
        return results.sorted { abs($0.diff) > abs($1.diff) }.prefix(6).map { $0 }
    }

    // MARK: Post check-in summary context
    struct CheckInContext {
        let metric: InsightMetric
        let value: Double
        let recentAvg: Double
        var observation: String {
            let diff = value - recentAvg
            let name = metric.rawValue.lowercased()
            let fmtAvg = String(format: "%.1f", recentAvg)
            
            if diff > 2.0 {
                return "Your \(name) is looking really good right now — noticeably above your recent average of \(fmtAvg)."
            } else if diff > 0.5 {
                return "Your \(name) is a little above your recent average (\(fmtAvg))."
            } else if diff < -2.0 {
                return "Your \(name) is lower than usual for you (your recent average is \(fmtAvg)). That's okay — you logged it, and that matters."
            } else if diff < -0.5 {
                return "Your \(name) is slightly below your recent average (\(fmtAvg))."
            } else {
                return "Your \(name) is right in line with how you've been lately (\(fmtAvg))."
            }
        }
    }

    static func checkInContext(newEntry: CheckIn, recentCheckIns: [CheckIn]) -> [CheckInContext] {
        InsightMetric.allCases.compactMap { m in
            guard let val = newEntry[keyPath: m.keyPath] else { return nil }
            let recVals = recentCheckIns.compactMap { $0[keyPath: m.keyPath] }
            guard !recVals.isEmpty else { return nil }
            let avg = recVals.reduce(0, +) / Double(recVals.count)
            return CheckInContext(metric: m, value: val, recentAvg: avg)
        }
    }
}

// MARK: - Root Tabs

struct ContentView: View {
    @State private var selectedTab = 0
    init() {
        let a = UITabBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        UITabBar.appearance().standardAppearance  = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()    .tabItem { Label("Log",      systemImage: "sparkles") }.tag(0)
            HistoryView() .tabItem { Label("History",  systemImage: "clock.fill") }.tag(1)
            InsightsView().tabItem { Label("Insights", systemImage: "chart.bar.fill") }.tag(2)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
        }
        .tint(.accentLilac)
    }
}

// MARK: - Home (Log)

struct HomeView: View {
    @Query(sort: \CheckIn.timestamp, order: .reverse) private var allCheckIns: [CheckIn]
    @State private var showingCheckInSheet = false
    @State private var buttonPressed = false
    @State private var lastSavedCheckIn: CheckIn? = nil
    @State private var showingSummary = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack {
                HStack {
                    Text("kairos.")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.textPrimary).padding(.top, 40)
                    Spacer()
                }.padding(.horizontal, 24)
                Spacer()
                VStack(spacing: 8) {
                    Text("Capture this moment.")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.textPrimary)
                    Text("A snapshot of you, right now.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.textSecondary)
                }.padding(.bottom, 34)

                Button { showingCheckInSheet = true } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.accentPink, .accentLilac], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 90, height: 90)
                            .shadow(color: .accentPink.opacity(0.5), radius: 16, x: 0, y: 8)
                            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 2))
                        Image(systemName: "sparkles").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .scaleEffect(buttonPressed ? 0.94 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: buttonPressed)
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in buttonPressed = true }
                    .onEnded   { _ in buttonPressed = false })
                Spacer(); Spacer()
            }
        }
        .sheet(isPresented: $showingCheckInSheet) {
            CheckInSheetView(onSaved: { entry in
                lastSavedCheckIn = entry
                showingSummary = true
            })
        }
        .sheet(isPresented: $showingSummary) {
            if let entry = lastSavedCheckIn {
                CheckInSummaryCard(checkIn: entry, recentCheckIns: Array(allCheckIns.prefix(30)))
            }
        }
        .onReceive(NotificationManager.shared.openCheckInPublisher) { _ in showingCheckInSheet = true }
    }
}

// MARK: - History

struct HistoryView: View {
    @Query(sort: \CheckIn.timestamp, order: .reverse) private var checkIns: [CheckIn]
    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if checkIns.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.questionmark").font(.system(size: 44, weight: .light)).foregroundStyle(.accentLilac)
                        Text("Your first moment is waiting.").font(.system(.body, design: .rounded)).foregroundStyle(Color.textSecondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(checkIns) { ci in
                                NavigationLink(destination: CheckInDetailView(checkIn: ci)) { HistoryRow(checkIn: ci) }
                                    .buttonStyle(PlainButtonStyle())
                            }
                        }.padding(20)
                    }
                }
            }.navigationTitle("History")
        }
    }
}

struct HistoryRow: View {
    let checkIn: CheckIn
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(checkIn.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                .font(.system(.headline, design: .rounded)).foregroundStyle(Color.textPrimary)
            let metrics = namedMetrics(checkIn)
            if metrics.isEmpty {
                Text("No metrics recorded").font(.system(.caption, design: .rounded)).foregroundStyle(Color.textSecondary)
            } else {
                Text(metrics.map { "\($0.0): \(String(format: "%.1f", $0.1))" }.joined(separator: ", "))
                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(.accentLilac).lineLimit(1)
            }
            if !checkIn.activityTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(checkIn.activityTags, id: \.self) { tag in
                        TappableTagChip(label: tag, accent: .accentLilac, pastel: .pastelLilac, filterType: .activity(tag))
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).tokenCard(cornerRadius: 20)
    }
}

// MARK: - Check-In Detail

struct CheckInDetailView: View {
    let checkIn: CheckIn
    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(checkIn.timestamp, format: Date.FormatStyle(date: .complete, time: .standard))
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.textSecondary).padding(.top, 10)
                    let metrics = namedMetrics(checkIn)
                    if !metrics.isEmpty {
                        SectionCard(title: "Metrics") {
                            VStack(spacing: 12) {
                                ForEach(metrics, id: \.0) { m in
                                    HStack {
                                        Text(m.0).font(.system(.subheadline, design: .rounded)).foregroundStyle(Color.textPrimary)
                                        Spacer()
                                        Text(String(format: "%.1f", m.1)).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(.accentPink)
                                    }
                                }
                            }
                        }
                    }
                    if !checkIn.activityTags.isEmpty {
                        SectionCard(title: "Activities") {
                            FlowLayout(spacing: 8) {
                                ForEach(checkIn.activityTags, id: \.self) { tag in
                                    TappableTagChip(label: tag, accent: .accentLilac, pastel: .pastelLilac, filterType: .activity(tag))
                                }
                            }
                        }
                    }
                    if let loc = checkIn.location, !loc.isEmpty {
                        SectionCard(title: "Location") {
                            TappableTagChip(label: "📍 \(loc)", accent: .accentBlue, pastel: .pastelBlue, filterType: .location(loc))
                        }
                    }
                    if let note = checkIn.journalNote, !note.isEmpty {
                        SectionCard(title: "Journal Note") { JournalNoteView(note: note) }
                    }
                }.padding(24)
            }
        }
        .navigationTitle("Check-In").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Post Check-In Summary Card

struct CheckInSummaryCard: View {
    let checkIn: CheckIn
    let recentCheckIns: [CheckIn]
    @Environment(\.dismiss) private var dismiss

    private var contexts: [Analytics.CheckInContext] {
        Analytics.checkInContext(newEntry: checkIn, recentCheckIns: recentCheckIns)
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(LinearGradient(colors: [.accentPink, .accentLilac], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Moment captured.")
                                    .font(.system(.title3, design: .rounded, weight: .bold))
                                    .foregroundStyle(Color.textPrimary)
                                Text(checkIn.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                                    .font(.system(.caption, design: .rounded)).foregroundStyle(Color.textSecondary)
                            }
                            Spacer()
                        }

                        // Logged metrics
                        let metrics = namedMetrics(checkIn)
                        if !metrics.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("YOU LOGGED").font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(Color.textSecondary).tracking(1.4)
                                ForEach(metrics, id: \.0) { m in
                                    HStack {
                                        let im = InsightMetric.allCases.first { $0.rawValue == m.0 }
                                        if let im = im {
                                            RoundedRectangle(cornerRadius: 2).fill(im.color).frame(width: 10, height: 10)
                                        }
                                        Text(m.0).font(.system(.subheadline, design: .rounded)).foregroundStyle(Color.textPrimary)
                                        Spacer()
                                        Text(String(format: "%.1f", m.1))
                                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                                            .foregroundStyle(InsightMetric.allCases.first { $0.rawValue == m.0 }?.color ?? .accentPink)
                                    }
                                }
                            }
                            .padding(16).background(Color.bgCard)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.textSecondary.opacity(0.12), lineWidth: 1))
                        }

                        // Tags summary
                        if !checkIn.activityTags.isEmpty || checkIn.location != nil || !checkIn.hashtags.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("CONTEXT").font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(Color.textSecondary).tracking(1.4)
                                FlowLayout(spacing: 8) {
                                    ForEach(checkIn.activityTags, id: \.self) { tag in
                                        TappableTagChip(label: tag, accent: .accentLilac, pastel: .pastelLilac, filterType: .activity(tag))
                                    }
                                    if let loc = checkIn.location, !loc.isEmpty {
                                        TappableTagChip(label: "📍 \(loc)", accent: .accentBlue, pastel: .pastelBlue, filterType: .location(loc))
                                    }
                                    ForEach(checkIn.hashtags, id: \.self) { h in
                                        TappableTagChip(label: "#\(h)", accent: .accentPink, pastel: .pastelPink, filterType: .hashtag(h))
                                    }
                                }
                            }
                            .padding(16).background(Color.bgCard)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.textSecondary.opacity(0.12), lineWidth: 1))
                        }

                        // Contextual observations vs recent average
                        if !contexts.isEmpty && !recentCheckIns.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("COMPARED TO RECENT").font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(Color.textSecondary).tracking(1.4)
                                ForEach(contexts.prefix(3), id: \.metric.id) { ctx in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: ctx.value >= ctx.recentAvg ? "arrow.up.right" : "arrow.down.right")
                                            .font(.system(.caption, weight: .semibold))
                                            .foregroundStyle(ctx.value >= ctx.recentAvg ? Color.accentTeal : Color.accentPink)
                                            .frame(width: 18)
                                        Text(ctx.observation).font(.system(.caption, design: .rounded)).foregroundStyle(Color.textPrimary)
                                    }
                                }
                            }
                            .padding(16).background(Color.bgCard)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.textSecondary.opacity(0.12), lineWidth: 1))
                        }

                        Button { dismiss() } label: {
                            Text("Done")
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(16)
                                .background(LinearGradient(colors: [.accentPink, .accentLilac], startPoint: .leading, endPoint: .trailing))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .padding(.top, 8)
                    }
                    .padding(24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(Color.textSecondary)
                    }
                }
            }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        }
    }
}

// CheckIn is already Identifiable via @Model — no extension needed.

// MARK: - Insights View

struct InsightsView: View {
    @Query(sort: \CheckIn.timestamp, order: .reverse) private var allCheckIns: [CheckIn]
    @State private var timeRange: TimeRange = .week
    @State private var selectedMetric: InsightMetric? = nil

    private var checkIns: [CheckIn] {
        guard let start = timeRange.startDate() else { return allCheckIns }
        return allCheckIns.filter { $0.timestamp >= start }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // ── Time Range Selector ──────────────────────────────
                        TimeRangePicker(selected: $timeRange)
                            .padding(.top, 8)
                            .onChange(of: timeRange) { selectedMetric = nil }

                        // ── Activity count ────────────────────────────────────
                        SectionCard(title: "Activity") {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(checkIns.count)")
                                    .font(.system(size: 48, weight: .bold, design: .rounded))
                                    .foregroundStyle(.accentPink)
                                Text("check-ins")
                                    .font(.system(.headline, design: .rounded))
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }

                        // ── Average metric bars ───────────────────────────────
                        SectionCard(title: "Average Metrics") {
                            VStack(spacing: 20) {
                                ForEach(InsightMetric.allCases) { m in StatBar(metric: m, checkIns: checkIns) }
                            }
                        }

                        // ── Metric observations ───────────────────────────────
                        let statsAll = InsightMetric.allCases.compactMap { MetricStats.compute(metric: $0, checkIns: checkIns) }
                        if !statsAll.isEmpty {
                            MetricObservationsCard(stats: statsAll)
                        }

                        // ── Trends chart with selector ────────────────────────
                        SectionCard(title: "Trends (\(timeRange.rawValue))") {
                            VStack(alignment: .leading, spacing: 16) {
                                MetricSelectorRow(selected: $selectedMetric)
                                TrendsChart(checkIns: checkIns, selectedMetric: selectedMetric)
                                    .frame(height: 240)
                                if let m = selectedMetric,
                                   let stats = statsAll.first(where: { $0.metric == m }) {
                                    MetricStatCard(stats: stats)
                                }
                            }
                        }

                        // ── Best / Worst ──────────────────────────────────────
                        if !checkIns.isEmpty { BestWorstCard(checkIns: checkIns) }

                        // ── Metric correlations ───────────────────────────────
                        let correlations = Analytics.metricCorrelations(checkIns: checkIns)
                        if !correlations.isEmpty {
                            RelationshipsCard(observations: correlations)
                        }

                        // ── Tag Insights ──────────────────────────────────────
                        let freq = Analytics.tagFrequency(checkIns: checkIns)
                        if !freq.activities.isEmpty || !freq.locations.isEmpty || !freq.hashtags.isEmpty {
                            TagInsightsCard(freq: freq)
                        }

                        // ── Tag Effects ───────────────────────────────────────
                        let effects = Analytics.tagEffects(checkIns: checkIns)
                        if !effects.isEmpty {
                            TagEffectsCard(effects: effects)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Insights")
        }
    }
}

// MARK: - Time Range Picker

struct TimeRangePicker: View {
    @Binding var selected: TimeRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TimeRange.allCases) { range in
                Button {
                    withAnimation(.spring(response: 0.3)) { selected = range }
                } label: {
                    Text(range.rawValue)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selected == range ? Color.white : Color.textSecondary)
                        .background(selected == range ? Color.accentLilac : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(4)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.textSecondary.opacity(0.15), lineWidth: 1))
        .shadow(color: Color.accentLilac.opacity(0.1), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Metric Observations Card

struct MetricObservationsCard: View {
    let stats: [MetricStats]

    var body: some View {
        SectionCard(title: "Observations") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(stats, id: \.metric.id) { s in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle().fill(s.metric.color.opacity(0.15)).frame(width: 28, height: 28)
                            Image(systemName: trendIcon(s.trendDirection))
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(s.metric.color)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.metric.rawValue)
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(Color.textPrimary)
                            Text(s.trendObservation)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func trendIcon(_ dir: Double) -> String {
        if dir > 0.3  { return "arrow.up.right" }
        if dir < -0.3 { return "arrow.down.right" }
        return "minus"
    }
}

// MARK: - Relationships Card

struct RelationshipsCard: View {
    let observations: [CorrelationObservation]

    var body: some View {
        SectionCard(title: "Relationships") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(observations.prefix(4).enumerated()), id: \.offset) { _, obs in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(Color.accentLilac)
                            .frame(width: 18)
                        Text(obs.text)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Tag Insights Card

struct TagInsightsCard: View {
    let freq: (activities: [(String, Int)], locations: [(String, Int)], hashtags: [(String, Int)])

    var body: some View {
        SectionCard(title: "Tag Insights") {
            VStack(alignment: .leading, spacing: 20) {
                if !freq.activities.isEmpty {
                    TagFrequencySection(title: "⚡ Activities", items: Array(freq.activities.prefix(5)), accent: .accentLilac, pastel: .pastelLilac) { .activity($0) }
                }
                if !freq.locations.isEmpty {
                    TagFrequencySection(title: "📍 Locations", items: Array(freq.locations.prefix(5)), accent: .accentBlue, pastel: .pastelBlue) { .location($0) }
                }
                if !freq.hashtags.isEmpty {
                    TagFrequencySection(title: "# Hashtags", items: Array(freq.hashtags.prefix(5)), accent: .accentPink, pastel: .pastelPink) { tag in .hashtag(tag) }
                }
            }
        }
    }
}

struct TagFrequencySection: View {
    let title: String
    let items: [(String, Int)]
    let accent: Color
    let pastel: Color
    let filterType: (String) -> FilterType

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(Color.textSecondary)

            let maxCount = items.first?.1 ?? 1
            VStack(spacing: 6) {
                ForEach(items, id: \.0) { item, count in
                    TagFrequencyRow(label: item, count: count, maxCount: maxCount,
                                    accent: accent, pastel: pastel,
                                    filterType: filterType(item))
                }
            }
        }
    }
}

struct TagFrequencyRow: View {
    let label: String
    let count: Int
    let maxCount: Int
    let accent: Color
    let pastel: Color
    let filterType: FilterType

    @State private var navigate = false
    @State private var pressed = false

    var body: some View {
        ZStack {
            NavigationLink(destination: FilteredEntriesView(filterType: filterType), isActive: $navigate) { EmptyView() }.hidden()

            Button { navigate = true } label: {
                HStack(spacing: 10) {
                    Text(label)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 90, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(pastel)
                            .frame(width: geo.size.width * CGFloat(count) / CGFloat(max(maxCount, 1)))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.7))
                                    .frame(width: geo.size.width * CGFloat(count) / CGFloat(max(maxCount, 1)))
                            }
                    }
                    .frame(height: 14)

                    Text("\(count)")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
            .scaleEffect(pressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false })
        }
    }
}

// MARK: - Tag Effects Card

struct TagEffectsCard: View {
    let effects: [Analytics.TagEffect]

    var body: some View {
        SectionCard(title: "Tag Effects") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(effects.enumerated()), id: \.offset) { _, effect in
                    TagEffectRow(effect: effect)
                }
            }
        }
    }
}

struct TagEffectRow: View {
    let effect: Analytics.TagEffect
    @State private var navigate = false

    var body: some View {
        ZStack {
            NavigationLink(destination: FilteredEntriesView(filterType: effect.filterType), isActive: $navigate) { EmptyView() }.hidden()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: effect.diff > 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(effect.diff > 0 ? Color.accentTeal : Color.accentPink)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(effect.observation)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { navigate = true } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
    }
}

// MARK: - Insight supporting types

enum InsightMetric: String, CaseIterable, Identifiable {
    case mood = "Mood"; case energy = "Energy"; case body = "Body"
    case clarity = "Clarity"; case social = "Social"
    var id: String { rawValue }
    var keyPath: KeyPath<CheckIn, Double?> {
        switch self {
        case .mood:    return \.mood
        case .energy:  return \.energy
        case .body:    return \.bodyComfort
        case .clarity: return \.clarity
        case .social:  return \.socialBattery
        }
    }
    var color: Color {
        switch self {
        case .mood:    return .chartMood
        case .energy:  return .chartEnergy
        case .body:    return .chartBody
        case .clarity: return .chartClarity
        case .social:  return .chartSocial
        }
    }
}

// MARK: - Metric Selector Row

struct MetricSelectorRow: View {
    @Binding var selected: InsightMetric?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { withAnimation(.spring(response: 0.3)) { selected = nil } } label: {
                    Text("All").font(.system(.caption, design: .rounded, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(selected == nil ? Color.textPrimary : Color.bgCard)
                        .foregroundStyle(selected == nil ? Color.bgPrimary : Color.textSecondary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.textSecondary.opacity(0.3), lineWidth: 1))
                }
                ForEach(InsightMetric.allCases) { m in
                    Button { withAnimation(.spring(response: 0.3)) { selected = selected == m ? nil : m } } label: {
                        Text(m.rawValue).font(.system(.caption, design: .rounded, weight: .bold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selected == m ? m.color : Color.bgCard)
                            .foregroundStyle(selected == m ? Color.white : Color.textSecondary)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(m.color.opacity(selected == m ? 0 : 0.5), lineWidth: 1))
                    }
                }
            }
        }
    }
}

// MARK: - Trends Chart

struct TrendsChart: View {
    let checkIns: [CheckIn]
    let selectedMetric: InsightMetric?
    var body: some View {
        Chart {
            ForEach(checkIns) { ci in
                ForEach(InsightMetric.allCases) { m in
                    if let v = ci[keyPath: m.keyPath] {
                        let active = selectedMetric == nil || selectedMetric == m
                        LineMark(x: .value("Time", ci.timestamp), y: .value("Value", v), series: .value("Metric", m.rawValue))
                            .foregroundStyle(m.color.opacity(active ? 1 : 0.10))
                            .lineStyle(StrokeStyle(lineWidth: selectedMetric == m ? 3 : (selectedMetric == nil ? 1.5 : 1)))
                            .interpolationMethod(.catmullRom)
                        if selectedMetric == m {
                            PointMark(x: .value("Time", ci.timestamp), y: .value("Value", v))
                                .foregroundStyle(m.color).symbolSize(30)
                        }
                    }
                }
            }
        }
        .chartYScale(domain: 0...10)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.textSecondary.opacity(0.2))
                AxisTick().foregroundStyle(Color.textSecondary.opacity(0.4))
                AxisValueLabel().foregroundStyle(Color.textSecondary).font(.system(.caption2, design: .rounded, weight: .medium))
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 2, 4, 6, 8, 10]) { _ in
                AxisGridLine().foregroundStyle(Color.textSecondary.opacity(0.2))
                AxisValueLabel().foregroundStyle(Color.textSecondary).font(.system(.caption2, design: .rounded, weight: .medium))
            }
        }
        .chartLegend(position: .bottom, alignment: .leading) {
            HStack(spacing: 12) {
                ForEach(InsightMetric.allCases) { m in
                    let active = selectedMetric == nil || selectedMetric == m
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(m.color.opacity(active ? 1 : 0.3)).frame(width: 14, height: 4)
                        Text(m.rawValue).font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(active ? Color.textPrimary : Color.textSecondary.opacity(0.5))
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Per-metric stat card (now driven by MetricStats)

struct MetricStatCard: View {
    let stats: MetricStats
    var metric: InsightMetric { stats.metric }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(metric.color).frame(width: 14, height: 4)
                Text(metric.rawValue).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Color.textPrimary)
            }
            HStack(spacing: 4) {
                Text("avg:").font(.system(.caption, design: .rounded)).foregroundStyle(Color.textSecondary)
                Text(String(format: "%.1f", stats.avg)).font(.system(.caption, design: .rounded, weight: .bold)).foregroundStyle(metric.color)
                Text("· std dev:").font(.system(.caption, design: .rounded)).foregroundStyle(Color.textSecondary)
                Text(String(format: "%.1f", stats.stdDev)).font(.system(.caption, design: .rounded, weight: .bold)).foregroundStyle(Color.textSecondary)
            }
            HStack(spacing: 20) {
                StatCallout(label: "High", value: stats.max, date: stats.maxEntry.timestamp, color: .accentTeal)
                Divider().frame(height: 40)
                StatCallout(label: "Low",  value: stats.min, date: stats.minEntry.timestamp, color: .accentPink)
            }
            Text(stats.trendObservation).font(.system(.caption, design: .rounded)).foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(metric.color.opacity(0.10)).background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(metric.color.opacity(0.25), lineWidth: 1.5))
    }
}

struct StatCallout: View {
    let label: String; let value: Double; let date: Date; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(.caption2, design: .rounded, weight: .semibold)).foregroundStyle(Color.textSecondary)
            Text(String(format: "%.1f", value)).font(.system(.callout, design: .rounded, weight: .bold)).foregroundStyle(color)
            Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                .font(.system(.caption2, design: .rounded)).foregroundStyle(Color.textSecondary)
        }
    }
}

// MARK: - Best / Worst card

struct BestWorstCard: View {
    let checkIns: [CheckIn]
    private var ranked: [(CheckIn, Double)] { checkIns.compactMap { ci in guard let a = ci.overallAverage else { return nil }; return (ci, a) } }
    private var best:  CheckIn? { ranked.max(by: { $0.1 < $1.1 })?.0 }
    private var worst: CheckIn? { ranked.min(by: { $0.1 < $1.1 })?.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PEAK MOMENTS").font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(Color.textSecondary).tracking(1.5).padding(.bottom, 12)
            VStack(spacing: 12) {
                if let b = best {
                    NavigationLink(destination: CheckInDetailView(checkIn: b)) {
                        MomentRow(icon: "sun.max.fill", label: "Best moment", checkIn: b, color: .accentTeal)
                    }.buttonStyle(PlainButtonStyle())
                }
                if let w = worst {
                    NavigationLink(destination: CheckInDetailView(checkIn: w)) {
                        MomentRow(icon: "cloud.rain.fill", label: "Hardest moment", checkIn: w, color: .accentPink)
                    }.buttonStyle(PlainButtonStyle())
                }
            }
        }
    }
}

struct MomentRow: View {
    let icon: String; let label: String; let checkIn: CheckIn; let color: Color
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(Color.textSecondary)
                Text(checkIn.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    .font(.system(.subheadline, design: .rounded, weight: .medium)).foregroundStyle(Color.textPrimary)
                if let a = checkIn.overallAverage {
                    Text("avg \(String(format: "%.1f", a)) across all metrics")
                        .font(.system(.caption2, design: .rounded)).foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(.caption, weight: .semibold)).foregroundStyle(Color.textSecondary)
        }
        .padding(14)
        .background(color.opacity(0.08)).background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(color.opacity(0.2), lineWidth: 1))
        .shadow(color: color.opacity(0.08), radius: 6, x: 0, y: 3)
    }
}

// MARK: - StatBar

struct StatBar: View {
    let metric: InsightMetric; let checkIns: [CheckIn]
    var body: some View {
        let values  = checkIns.compactMap { $0[keyPath: metric.keyPath] }
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metric.rawValue).font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Color.textPrimary)
                Spacer()
                if let a = average {
                    Text(String(format: "%.1f", a)).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(metric.color)
                } else { Text("--").foregroundStyle(Color.textSecondary) }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.textSecondary.opacity(0.15)).frame(height: 4)
                    if let a = average {
                        let pct = CGFloat(a / 10)
                        let x   = max(8, min(geo.size.width - 8, geo.size.width * pct))
                        Circle()
                            .fill(LinearGradient(colors: [metric.color, .accentLilac], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 16, height: 16)
                            .shadow(color: metric.color.opacity(0.3), radius: 3, x: 0, y: 2)
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                            .position(x: x, y: geo.size.height / 2)
                    }
                }
            }.frame(height: 20)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Query(sort: \CheckIn.timestamp, order: .reverse) private var checkIns: [CheckIn]
    @AppStorage("reminderFrequency") private var frequency: ReminderFrequency = .off
    @AppStorage("reminderStartHour") private var startHour: Int = 9
    @AppStorage("reminderEndHour")   private var endHour:   Int = 21
    @State private var csvURL: URL?

    func generateCSVURL() -> URL {
        var csv = "Timestamp,Mood,Energy,Body Comfort,Clarity,Social Battery,Location,Notes,Activities,Hashtags\n"
        let fmt = ISO8601DateFormatter()
        for c in checkIns {
            let ts      = fmt.string(from: c.timestamp)
            let mood    = c.mood.map          { String(format: "%.1f", $0) } ?? ""
            let energy  = c.energy.map        { String(format: "%.1f", $0) } ?? ""
            let body    = c.bodyComfort.map   { String(format: "%.1f", $0) } ?? ""
            let clarity = c.clarity.map       { String(format: "%.1f", $0) } ?? ""
            let social  = c.socialBattery.map { String(format: "%.1f", $0) } ?? ""
            let loc     = "\"\(c.location ?? "")\""
            let note    = "\"\(c.journalNote?.replacingOccurrences(of: "\"", with: "\"\"") ?? "")\""
            let acts    = "\"\(c.activityTags.joined(separator: ", "))\""
            let tags    = "\"\(c.hashtags.joined(separator: ", "))\""
            csv += [ts, mood, energy, body, clarity, social, loc, note, acts, tags].joined(separator: ",") + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kairos_Export.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 24) {
                        Image(systemName: "hourglass.circle").font(.system(size: 80, weight: .light))
                            .foregroundStyle(.accentPink).padding(.top, 40)
                        Text("Kairos v1.0").font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(Color.textPrimary)

                        SectionCard(title: "Reminders") {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("Gentle pings asking how you are doing. No streaks, no guilt.")
                                    .font(.system(.caption, design: .rounded)).foregroundStyle(Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                LabeledPicker(label: "Frequency", selection: $frequency, tint: .accentPink) {
                                    ForEach(ReminderFrequency.allCases, id: \.self) { f in Text(f.rawValue).tag(f) }
                                }
                                if frequency != .off {
                                    LabeledPicker(label: "Start Time", selection: $startHour, tint: .accentLilac) {
                                        ForEach(0..<24) { h in Text(hourLabel(h)).tag(h) }
                                    }
                                    LabeledPicker(label: "End Time", selection: $endHour, tint: .accentLilac) {
                                        ForEach(0..<24) { h in Text(hourLabel(h)).tag(h) }
                                    }
                                }
                                Button {
                                    NotificationManager.shared.requestPermission()
                                    NotificationManager.shared.scheduleNotifications(frequency: frequency, startHour: startHour, endHour: endHour)
                                } label: {
                                    Text("Save Reminders").font(.system(.subheadline, design: .rounded, weight: .bold))
                                        .foregroundStyle(.white).frame(maxWidth: .infinity).padding(14)
                                        .background(.accentPink).clipShape(RoundedRectangle(cornerRadius: 12))
                                }.padding(.top, 6)
                            }
                        }

                        SectionCard(title: "Account & Sync") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "icloud").foregroundStyle(.accentBlue)
                                    Text("iCloud Sync enabled").font(.system(.subheadline, design: .rounded)).foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    Text("WIP").font(.system(.caption, design: .rounded, weight: .bold))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.textSecondary.opacity(0.12)).clipShape(Capsule())
                                        .foregroundStyle(Color.textSecondary)
                                }
                                Text("Your data is securely stored locally on your device.")
                                    .font(.system(.caption, design: .rounded)).foregroundStyle(Color.textSecondary)
                            }
                        }

                        SectionCard(title: "Data") {
                            if let url = csvURL {
                                ShareLink(item: url) {
                                    Text("Export Data (CSV)").font(.system(.subheadline, design: .rounded, weight: .medium)).foregroundStyle(.accentPink)
                                }
                            } else {
                                Button { csvURL = generateCSVURL() } label: {
                                    Text("Prepare Export (CSV)").font(.system(.subheadline, design: .rounded, weight: .medium)).foregroundStyle(.accentPink)
                                }
                            }
                        }
                    }.padding(24)
                }
            }.navigationTitle("Settings")
        }
    }
    private func hourLabel(_ h: Int) -> String {
        h == 0 ? "12 AM" : h < 12 ? "\(h) AM" : h == 12 ? "12 PM" : "\(h-12) PM"
    }
}

// MARK: - FilteredEntriesView

struct FilteredEntriesView: View {
    let filterType: FilterType
    @Query(sort: \CheckIn.timestamp, order: .reverse) private var all: [CheckIn]
    private var filtered: [CheckIn] {
        all.filter { ci in
            switch filterType {
            case .activity(let t): return ci.activityTags.contains(t)
            case .location(let l): return ci.location?.lowercased() == l.lowercased()
            case .hashtag(let t):  return ci.hashtags.contains(t.lowercased())
            }
        }
    }
    var body: some View {
        ZStack {
            AppBackground()
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 38, weight: .light)).foregroundStyle(.accentLilac)
                    Text(filterType.emptyStateMessage).multilineTextAlignment(.center)
                        .foregroundStyle(Color.textSecondary).font(.system(.body, design: .rounded)).padding(.horizontal, 32)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(filtered) { ci in
                            NavigationLink(destination: CheckInDetailView(checkIn: ci)) { FilteredEntryRow(checkIn: ci) }
                                .buttonStyle(PlainButtonStyle())
                        }
                    }.padding(20)
                }
            }
        }
        .navigationTitle(filterType.displayTitle).navigationBarTitleDisplayMode(.large)
    }
}

struct FilteredEntryRow: View {
    let checkIn: CheckIn
    private var metricSummary: String {
        [checkIn.mood.map { "Mood \(String(format: "%.1f", $0))" },
         checkIn.energy.map { "Energy \(String(format: "%.1f", $0))" },
         checkIn.bodyComfort.map { "Body \(String(format: "%.1f", $0))" },
         checkIn.clarity.map { "Clarity \(String(format: "%.1f", $0))" },
         checkIn.socialBattery.map { "Social \(String(format: "%.1f", $0))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(checkIn.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                .font(.system(.headline, design: .rounded)).foregroundStyle(Color.textPrimary)
            if !metricSummary.isEmpty {
                Text(metricSummary).font(.system(.caption, design: .rounded)).foregroundStyle(.accentLilac).lineLimit(1)
            }
            if let note = checkIn.journalNote, !note.isEmpty {
                let preview = note.count > 60 ? String(note.prefix(60)) + "…" : note
                Text(preview).font(.system(.subheadline, design: .rounded)).foregroundStyle(Color.textPrimary).lineLimit(2)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).tokenCard(cornerRadius: 20)
    }
}

// MARK: - TappableTagChip

struct TappableTagChip: View {
    let label: String; let accent: Color; let pastel: Color; let filterType: FilterType
    @State private var pressed = false; @State private var navigate = false
    var body: some View {
        ZStack {
            NavigationLink(destination: FilteredEntriesView(filterType: filterType), isActive: $navigate) { EmptyView() }.hidden()
            Button { navigate = true } label: {
                Text(label).font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(accent).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(pastel).clipShape(Capsule())
                    .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1))
            }
            .scaleEffect(pressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
        }
    }
}

// MARK: - JournalNoteView

struct JournalNoteView: View {
    let note: String
    @State private var selectedHashtag: String? = nil
    @State private var showHashtag = false
    var body: some View {
        Text(attributedNote)
            .font(.system(.body, design: .rounded)).foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true).tint(.accentPink)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "hashtag", let host = url.host else { return .systemAction }
                selectedHashtag = host; showHashtag = true; return .handled
            })
            .background(
                NavigationLink(destination: Group {
                    if let t = selectedHashtag { FilteredEntriesView(filterType: .hashtag(t)) }
                }, isActive: $showHashtag) { EmptyView() }.hidden()
            )
    }
    private var attributedNote: AttributedString {
        var result = AttributedString()
        guard let regex = try? NSRegularExpression(pattern: "#[^\\s]+") else { return AttributedString(note) }
        let matches = regex.matches(in: note, range: NSRange(location: 0, length: note.utf16.count))
        var current = note.startIndex
        for match in matches {
            guard let range = Range(match.range, in: note) else { continue }
            if range.lowerBound > current { result.append(AttributedString(String(note[current..<range.lowerBound]))) }
            let token = String(note[range]); var core = token.drop(while: { $0 == "#" })
            while let last = core.last, last.isPunctuation { core = core.dropLast() }
            let norm = String(core).lowercased()
            var attr = AttributedString(token)
            if !norm.isEmpty, let enc = norm.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) {
                attr.link = URL(string: "hashtag://\(enc)")
                attr.foregroundColor = UIColor(Color.accentPink); attr.underlineStyle = .single
            }
            result.append(attr); current = range.upperBound
        }
        if current < note.endIndex { result.append(AttributedString(String(note[current...]))) }
        return result
    }
}

// MARK: - Shared UI Infrastructure

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.bgPrimary.ignoresSafeArea()
            LinearGradient(colors: [Color.accentBlue.opacity(0.18), Color.accentLilac.opacity(0.14), Color.accentPink.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String; @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased()).font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(Color.textSecondary).tracking(1.4)
            content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.accentLilac.opacity(0.12), radius: 12, x: 0, y: 5)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.textSecondary.opacity(0.12), lineWidth: 1))
        }
    }
}

extension View {
    func tokenCard(cornerRadius: CGFloat = 24) -> some View {
        self.background(Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.accentLilac.opacity(0.12), radius: 10, x: 0, y: 4)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.textSecondary.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - CheckInSheetView subcomponents

struct HeaderSection: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("Capture this moment.").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Color.textPrimary)
            Text("A snapshot of you, right now.").font(.system(.subheadline, design: .rounded)).foregroundStyle(Color.textSecondary)
        }.multilineTextAlignment(.center).padding(.top, 20)
    }
}

struct MetricsSection: View {
    @Binding var mood: Double?; @Binding var energy: Double?; @Binding var bodyComfort: Double?
    @Binding var clarity: Double?; @Binding var socialBattery: Double?
    var body: some View {
        VStack(spacing: 28) {
            OptionalMetricRow(question: "How is your mood right now?",      lowLabel: "terrible",   highLabel: "great",           value: $mood,          tint: .accentPink)
            OptionalMetricRow(question: "How energized or drained?",        lowLabel: "empty",      highLabel: "wired",           value: $energy,        tint: .accentLilac)
            OptionalMetricRow(question: "How comfortable is your body?",    lowLabel: "in pain",    highLabel: "relaxed",         value: $bodyComfort,   tint: .accentBlue)
            OptionalMetricRow(question: "How clear is your mind?",          lowLabel: "foggy",      highLabel: "focused",         value: $clarity,       tint: .accentPink)
            OptionalMetricRow(question: "How is your social battery?",      lowLabel: "need space", highLabel: "need connection", value: $socialBattery, tint: .accentLilac)
        }
    }
}

struct ActivityTagsSection: View {
    @Binding var tagOptions: [String]; @Binding var selectedTags: Set<String>; @Binding var newTag: String
    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Text("Activity Tags").font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(Color.textPrimary)
            FlowLayout(spacing: 12) {
                ForEach(tagOptions, id: \.self) { tag in
                    ChipButton(title: tag, isSelected: selectedTags.contains(tag)) {
                        if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                    }
                }
            }
            HStack {
                TextField("Add custom tag...", text: $newTag).font(.system(.body, design: .rounded))
                    .padding(10).background(Color.bgCard).cornerRadius(12).foregroundStyle(Color.textPrimary)
                Button {
                    let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !t.isEmpty, !tagOptions.contains(t) { tagOptions.append(t); selectedTags.insert(t) }
                    newTag = ""
                } label: { Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.accentPink) }
            }.padding(.top, 4)
        }
    }
}

struct LocationSection: View {
    let locationOptions: [String]; @Binding var selectedLocation: String?
    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Text("Location").font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(Color.textPrimary)
            FlowLayout(spacing: 12) {
                ForEach(locationOptions, id: \.self) { loc in
                    ChipButton(title: loc, isSelected: selectedLocation == loc) { selectedLocation = selectedLocation == loc ? nil : loc }
                }
            }
        }
    }
}

struct JournalNoteSection: View {
    @Binding var journalNote: String
    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Text("Journal Note").font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(Color.textPrimary)
            TextField("Add a note...", text: $journalNote, axis: .vertical).lineLimit(4...8)
                .padding(16).font(.system(.body, design: .rounded)).foregroundStyle(Color.textPrimary)
                .background(Color.bgCard).cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.textSecondary.opacity(0.2), lineWidth: 1))
        }
    }
}

struct SaveButtonSection: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Spacer()
                Text("Save check-in").font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(.white)
                Spacer() }.padding(20)
            .background(LinearGradient(colors: [.accentPink, .accentLilac], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.accentPink.opacity(0.35), radius: 10, x: 0, y: 5)
        }
    }
}

// MARK: - CheckInSheetView

struct CheckInSheetView: View {
    var onSaved: ((CheckIn) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var mood: Double? = nil; @State private var energy: Double? = nil
    @State private var bodyComfort: Double? = nil; @State private var clarity: Double? = nil
    @State private var socialBattery: Double? = nil
    @State private var selectedTags: Set<String> = []; @State private var selectedLocation: String? = nil
    @State private var journalNote = ""
    @State private var tagOptions = ["coding","studying","housekeeping","hustling","hobbying","eating","social","resting","lounging","other"]
    @State private var newTag = ""
    let locationOptions = ["home","work","outside","other"]

    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .center, spacing: 36) {
                        HeaderSection()
                        MetricsSection(mood: $mood, energy: $energy, bodyComfort: $bodyComfort, clarity: $clarity, socialBattery: $socialBattery)
                        VStack(alignment: .center, spacing: 28) {
                            ActivityTagsSection(tagOptions: $tagOptions, selectedTags: $selectedTags, newTag: $newTag)
                            LocationSection(locationOptions: locationOptions, selectedLocation: $selectedLocation)
                            JournalNoteSection(journalNote: $journalNote)
                        }.padding(.top, 12)
                        SaveButtonSection(action: saveCheckIn).padding(.top, 30).padding(.bottom, 50)
                    }.padding(.horizontal, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(Color.textSecondary) }
                }
            }
        }
    }

    private func saveCheckIn() {
        let entry = CheckIn(mood: mood, energy: energy, bodyComfort: bodyComfort, clarity: clarity, socialBattery: socialBattery,
                            activityTags: Array(selectedTags).sorted(), location: selectedLocation,
                            journalNote: journalNote.isEmpty ? nil : journalNote)
        modelContext.insert(entry)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onSaved?(entry) }
    }
}

// MARK: - OptionalMetricRow

struct OptionalMetricRow: View {
    let question: String; let lowLabel: String; let highLabel: String
    @Binding var value: Double?; let tint: Color
    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Text(question).font(.system(.headline, design: .rounded, weight: .semibold)).foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if value == nil {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { value = 5 } } label: {
                    Text("Answer").font(.system(.subheadline, design: .rounded, weight: .bold))
                        .padding(.horizontal, 22).padding(.vertical, 12).background(Color.bgCard).clipShape(Capsule())
                        .foregroundStyle(Color.textPrimary).shadow(color: Color.accentLilac.opacity(0.15), radius: 4, x: 0, y: 2)
                }
            } else {
                VStack(spacing: 8) {
                    Slider(value: Binding(get: { value ?? 5 }, set: { value = $0 }), in: 0...10, step: 0.1).tint(tint).padding(.horizontal, 4)
                    HStack {
                        Text("0 – \(lowLabel)").font(.system(.caption, design: .rounded)).foregroundStyle(Color.textSecondary)
                        Spacer()
                        Text(String(format: "%.1f", value ?? 5)).font(.system(.headline, design: .monospaced, weight: .bold)).foregroundStyle(tint)
                        Spacer()
                        Text("10 – \(highLabel)").font(.system(.caption, design: .rounded)).foregroundStyle(Color.textSecondary)
                    }.padding(.bottom, 6)
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { value = nil } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark").font(.system(.caption2, weight: .bold))
                            Text("Clear").font(.system(.caption, design: .rounded, weight: .bold))
                        }.foregroundStyle(Color.textSecondary).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.textSecondary.opacity(0.12)).clipShape(Capsule())
                    }
                }.padding(20).background(Color.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.textSecondary.opacity(0.15), lineWidth: 1))
            }
        }.padding(.vertical, 8)
    }
}

// MARK: - ChipButton

struct ChipButton: View {
    let title: String; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(.subheadline, design: .rounded, weight: .medium))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(isSelected ? Color.accentLilac : Color.bgCard)
                .foregroundStyle(isSelected ? Color.white : Color.textPrimary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.clear : Color.textSecondary.opacity(0.2), lineWidth: 1))
                .shadow(color: isSelected ? Color.accentLilac.opacity(0.3) : .clear, radius: 5, x: 0, y: 2)
                .scaleEffect(isSelected ? 1.05 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        }
    }
}

// MARK: - Helpers

func namedMetrics(_ ci: CheckIn) -> [(String, Double)] {
    [("Mood", ci.mood), ("Energy", ci.energy), ("Body", ci.bodyComfort),
     ("Clarity", ci.clarity), ("Social", ci.socialBattery)].compactMap { $0.1 != nil ? ($0.0, $0.1!) : nil }
}

struct LabeledPicker<SelectionValue: Hashable, Content: View>: View {
    let label: String; @Binding var selection: SelectionValue; let tint: Color; @ViewBuilder let content: Content
    var body: some View {
        HStack {
            Text(label).font(.system(.subheadline, design: .rounded)).foregroundStyle(Color.textPrimary)
            Spacer()
            Picker(label, selection: $selection) { content }.tint(tint)
        }
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        flow(in: proposal.width ?? 0, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = flow(in: bounds.width, subviews: subviews)
        for (ri, row) in result.rows.enumerated() {
            var x = bounds.minX
            for sv in row {
                sv.place(at: CGPoint(x: x, y: bounds.minY + result.yOffsets[ri]), proposal: .unspecified)
                x += sv.sizeThatFits(.unspecified).width + spacing
            }
        }
    }
    private func flow(in maxW: CGFloat, subviews: Subviews) -> (rows: [[LayoutSubview]], yOffsets: [CGFloat], size: CGSize) {
        var rows: [[LayoutSubview]] = []; var yOff: [CGFloat] = []
        var row: [LayoutSubview] = []; var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxW, !row.isEmpty { rows.append(row); yOff.append(y); y += rowH + spacing; row = []; x = 0; rowH = 0 }
            row.append(sv); x += s.width + spacing; rowH = max(rowH, s.height)
        }
        if !row.isEmpty { rows.append(row); yOff.append(y); y += rowH }
        return (rows, yOff, CGSize(width: maxW, height: y))
    }
}
