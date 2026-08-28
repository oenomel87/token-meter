import AppKit
import Charts
import SwiftUI
import TokenMeterCore

private struct LimitMetric: Identifiable {
    enum Source {
        case codex
        case claude
    }

    let id: String
    let source: Source
    let title: String
    let usedPercentage: Double
    let resetsAt: Date?

    func isActive(asOf now: Date) -> Bool {
        guard let resetsAt else { return true }
        return resetsAt > now
    }
}

private extension UsageHealthLevel {
    var systemImageName: String {
        switch self {
        case .sun: "sun.max.fill"
        case .cloud: "cloud.fill"
        case .rain: "cloud.rain.fill"
        case .thunder: "cloud.bolt.rain.fill"
        case .alert: "exclamationmark.triangle.fill"
        case .xmark: "xmark.octagon.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .sun: "여유 있음"
        case .cloud: "사용량 증가"
        case .rain: "확인 권장"
        case .thunder: "높은 사용량"
        case .alert: "즉시 확인 필요"
        case .xmark: "한도 임박"
        case .unavailable: "측정 불가"
        }
    }
}

private extension CodexRateLimitReadFailure {
    var userMessage: String {
        switch self {
        case .executableNotFound:
            "Codex CLI를 찾지 못했습니다. Codex가 설치되어 있는지 확인한 뒤 새로고침하세요."
        case .cliLaunchFailed:
            "Codex CLI를 실행하지 못했습니다. Codex 또는 Node.js 설치 상태를 확인한 뒤 새로고침하세요."
        case .initializationFailed:
            "Codex App Server를 초기화하지 못했습니다. Codex CLI를 업데이트한 뒤 다시 시도하세요."
        case .rateLimitRequestFailed:
            "Codex 사용 한도를 받지 못했습니다. Codex 로그인 상태와 네트워크 연결을 확인하세요."
        case .invalidResponse:
            "Codex 사용 한도 응답을 해석하지 못했습니다. Codex CLI 업데이트 후 호환성 확인이 필요합니다."
        }
    }
}

@main
struct TokenMeterApp: App {
    @StateObject private var monitor = UsageMonitor()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            TokenMeterView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class UsageMonitor: ObservableObject {
    @Published private(set) var report = UsageReport.empty
    @Published private(set) var rateLimits: RateLimitSnapshot?
    @Published private(set) var codexRateLimits: CodexRateLimitSnapshot?
    @Published private(set) var codexRateLimitFailure: CodexRateLimitReadFailure?
    @Published private(set) var bridgeInstalled = false
    @Published private(set) var bridgeMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var displayPeriod: DisplayPeriod = .today

    private let bridge = StatusLineBridge()
    private var timer: Timer?
    private var refreshID = UUID()
    private var pendingRefreshParts = 0

    init() {
        if let stored = UserDefaults.standard.string(forKey: "tokenMeterDisplayPeriod"),
           let displayPeriod = DisplayPeriod(rawValue: stored) {
            self.displayPeriod = displayPeriod
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        bridgeInstalled = bridge.isInstalled

        let currentRefreshID = UUID()
        refreshID = currentRefreshID
        pendingRefreshParts = 3

        Task { [weak self] in
            let value = await Task.detached(priority: .utility) {
                TokenUsageScanner().scan()
            }.value
            guard let self, self.refreshID == currentRefreshID else { return }
            self.report = value
            self.finishRefreshPart(currentRefreshID)
        }

        Task { [weak self] in
            let value = await Task.detached(priority: .utility) {
                RateLimitReader().read()
            }.value
            guard let self, self.refreshID == currentRefreshID else { return }
            self.rateLimits = value
            self.finishRefreshPart(currentRefreshID)
        }

        Task { [weak self] in
            let value = await Task.detached(priority: .utility) {
                CodexRateLimitReader().readResult()
            }.value
            guard let self, self.refreshID == currentRefreshID else { return }
            switch value {
            case let .success(snapshot):
                self.codexRateLimits = snapshot
                self.codexRateLimitFailure = nil
            case let .failure(failure):
                self.codexRateLimits = nil
                self.codexRateLimitFailure = failure
            }
            self.finishRefreshPart(currentRefreshID)
        }
    }

    private func finishRefreshPart(_ id: UUID) {
        guard refreshID == id else { return }
        pendingRefreshParts -= 1
        if pendingRefreshParts == 0 {
            isRefreshing = false
        }
    }

    /// Claude Code hands the subscription limits to the status line command and
    /// nowhere else, so the app has to sit behind one to see them.
    func installBridge() {
        do {
            let backup = try bridge.install()
            bridgeInstalled = bridge.isInstalled
            var message = "연동을 켰습니다. 다음 Claude Code 응답부터 값이 채워집니다."
            if let backup {
                message += " 기존 설정 백업: \(backup.lastPathComponent)"
            }
            bridgeMessage = message
            refresh()
        } catch {
            bridgeMessage = "연동 실패: \(error.localizedDescription)"
        }
    }

    func uninstallBridge() {
        do {
            try bridge.uninstall()
            bridgeInstalled = bridge.isInstalled
            bridgeMessage = "연동을 껐습니다. 이전 상태줄 명령을 되돌렸습니다."
        } catch {
            bridgeMessage = "해제 실패: \(error.localizedDescription)"
        }
    }

    func selectDisplayPeriod(_ period: DisplayPeriod) {
        displayPeriod = period
        UserDefaults.standard.set(period.rawValue, forKey: "tokenMeterDisplayPeriod")
    }

    var now: Date { Date() }

    var activeLimitMetrics: [LimitMetric] {
        var metrics: [LimitMetric] = []

        if let snapshot = codexRateLimits {
            for bucket in snapshot.buckets where !bucket.isCodexSpark {
                let bucketTitle = codexBucketTitle(bucket)
                if let window = bucket.primary {
                    metrics.append(LimitMetric(
                        id: "codex.\(bucket.id).primary",
                        source: .codex,
                        title: "\(bucketTitle) · 주 한도 · \(windowTitle(window))",
                        usedPercentage: window.usedPercentage,
                        resetsAt: window.resetsAt
                    ))
                }
                if let window = bucket.secondary {
                    metrics.append(LimitMetric(
                        id: "codex.\(bucket.id).secondary",
                        source: .codex,
                        title: "\(bucketTitle) · 보조 한도 · \(windowTitle(window))",
                        usedPercentage: window.usedPercentage,
                        resetsAt: window.resetsAt
                    ))
                }
            }
        }

        if bridgeInstalled, let snapshot = rateLimits {
            if let window = snapshot.fiveHour {
                metrics.append(LimitMetric(
                    id: "claude.five-hour",
                    source: .claude,
                    title: "Claude · 5시간",
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt
                ))
            }
            if let window = snapshot.sevenDay {
                metrics.append(LimitMetric(
                    id: "claude.seven-day",
                    source: .claude,
                    title: "Claude · 7일",
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt
                ))
            }
        }

        return metrics
            .filter { $0.isActive(asOf: now) }
            .sorted { $0.usedPercentage > $1.usedPercentage }
    }

    var leadingLimitMetric: LimitMetric? { activeLimitMetrics.first }

    var usageHealthLevel: UsageHealthLevel {
        UsageHealthLevel(maximumUsedPercentage: leadingLimitMetric?.usedPercentage)
    }

    var hasActiveCodexMeasurement: Bool {
        activeLimitMetrics.contains(where: { $0.source == .codex })
    }

    var hasActiveClaudeMeasurement: Bool {
        activeLimitMetrics.contains(where: { $0.source == .claude })
    }

    var menuTooltip: String {
        var lines: [String] = []
        if let leading = leadingLimitMetric {
            var headline = "\(usageHealthLevel.title): \(leading.title) · \(percentText(leading.usedPercentage)) 사용"
            if let reset = resetText(leading.resetsAt, now: now) {
                headline += " · \(reset)"
            }
            lines.append(headline)
        } else {
            lines.append("측정 가능한 사용 한도가 없습니다.")
        }

        if !hasActiveCodexMeasurement {
            lines.append("Codex: 측정 불가")
        }
        if !hasActiveClaudeMeasurement {
            if !bridgeInstalled {
                lines.append("Claude: 상태줄 연동 필요")
            } else if rateLimits == nil {
                lines.append("Claude: 첫 응답 대기")
            } else {
                lines.append("Claude: 리셋 후 새 응답 대기")
            }
        }
        var tokenLine = "\(displayPeriod.title) 사용 토큰: \(selectedUsage.total.tokenText)"
        if selectedCost > 0 {
            tokenLine += " · 기록 비용 \(selectedCost.costText)"
        }
        lines.append(tokenLine)
        return lines.joined(separator: "\n")
    }

    var selectedStartDate: Date {
        Calendar.current.startOfDay(for: displayPeriod.startDate(reference: report.refreshedAt))
    }

    var selectedUsage: TokenUsage {
        report.combinedSummary(since: selectedStartDate)
    }

    var selectedCost: Double {
        report.combinedCost(since: selectedStartDate)
    }

    func summary(for provider: Provider) -> ProviderSummary {
        report.summary(for: provider, since: selectedStartDate)
    }
}

private enum DisplayPeriod: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "오늘"
        case .last7Days: "7일"
        case .last30Days: "30일"
        }
    }

    func startDate(reference: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        switch self {
        case .today:
            return today
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .last30Days:
            return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        Image(systemName: monitor.usageHealthLevel.systemImageName)
            .symbolRenderingMode(.monochrome)
            .accessibilityLabel("토큰 미터: \(monitor.usageHealthLevel.title)")
            .help(monitor.menuTooltip)
    }
}

private func percentText(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

private func resetText(_ date: Date?, now: Date) -> String? {
    guard let date else { return nil }
    let interval = date.timeIntervalSince(now)
    guard interval > 0 else { return "리셋됨" }

    let totalMinutes = Int(interval / 60)
    let days = totalMinutes / 1_440
    let hours = (totalMinutes % 1_440) / 60
    let minutes = totalMinutes % 60
    if days > 0 { return "\(days)일 \(hours)시간 후 리셋" }
    if hours > 0 { return "\(hours)시간 \(minutes)분 후 리셋" }
    return "\(max(minutes, 1))분 후 리셋"
}

private func windowTitle(_ window: CodexRateLimitWindow?) -> String {
    guard let minutes = window?.durationMinutes else { return "한도" }
    switch minutes {
    case 60: return "1시간"
    case 300: return "5시간"
    case 1_440: return "1일"
    case 10_080: return "7일"
    default: return "\(minutes)분"
    }
}

private func codexBucketTitle(_ bucket: CodexRateLimitBucket) -> String {
    if let name = bucket.name, !name.isEmpty {
        return "Codex \(name)"
    }
    if bucket.id == "codex" {
        return "Codex 기본"
    }
    return "Codex \(bucket.id)"
}

private struct CodexLimitRow: Identifiable {
    let id: String
    let title: String
    let window: CodexRateLimitWindow
}

private func codexLimitRows(_ snapshot: CodexRateLimitSnapshot) -> [CodexLimitRow] {
    snapshot.buckets
        .filter { !$0.isCodexSpark }
        .flatMap { bucket -> [CodexLimitRow] in
            var rows: [CodexLimitRow] = []
            let title = codexBucketTitle(bucket)
            if let primary = bucket.primary {
                rows.append(CodexLimitRow(
                    id: "\(bucket.id).primary",
                    title: "\(title) · 주 한도 · \(windowTitle(primary))",
                    window: primary
                ))
            }
            if let secondary = bucket.secondary {
                rows.append(CodexLimitRow(
                    id: "\(bucket.id).secondary",
                    title: "\(title) · 보조 한도 · \(windowTitle(secondary))",
                    window: secondary
                ))
            }
            return rows
        }
        .sorted { $0.window.usedPercentage > $1.window.usedPercentage }
}

private func relativeText(_ date: Date, now: Date) -> String {
    let seconds = Int(max(now.timeIntervalSince(date), 0))
    if seconds < 90 { return "방금" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)분 전" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)시간 전" }
    return "\(hours / 24)일 전"
}

private func limitTint(_ usedPercentage: Double) -> Color {
    switch UsageHealthLevel(maximumUsedPercentage: usedPercentage) {
    case .sun: .green
    case .cloud: .teal
    case .rain: .blue
    case .thunder: .orange
    case .alert: .red
    case .xmark: .red
    case .unavailable: .secondary
    }
}

private struct TokenMeterView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("토큰 미터")
                        .font(.headline)
                    Text("Codex · Claude · opencode 로컬 세션 로그")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(monitor.report.refreshedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CodexSubscriptionLimitsView(monitor: monitor)

            SubscriptionLimitsView(monitor: monitor)

            Picker(
                "기간",
                selection: Binding(
                    get: { monitor.displayPeriod },
                    set: { monitor.selectDisplayPeriod($0) }
                )
            ) {
                ForEach(DisplayPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)

            TotalUsageView(usage: monitor.selectedUsage, recordedCost: monitor.selectedCost, period: monitor.displayPeriod)

            HStack(alignment: .top, spacing: 12) {
                ProviderUsageView(
                    provider: .codex,
                    summary: monitor.summary(for: .codex),
                    color: .green
                )
                ProviderUsageView(
                    provider: .claude,
                    summary: monitor.summary(for: .claude),
                    color: .orange
                )
                ProviderUsageView(
                    provider: .opencode,
                    summary: monitor.summary(for: .opencode),
                    color: .blue
                )
            }

            UsageChart(items: monitor.report.dailyUsage(days: 14))

            if monitor.report.skippedFileCount > 0 {
                Label("읽지 못한 로그 파일 \(monitor.report.skippedFileCount)개", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("데이터는 이 Mac 밖으로 전송하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    monitor.refresh()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isRefreshing)

                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 450)
    }
}

private struct CodexSubscriptionLimitsView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Codex 사용 한도")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let snapshot = monitor.codexRateLimits {
                    Text("\(relativeText(snapshot.capturedAt, now: monitor.now)) 조회")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = monitor.codexRateLimits {
                ForEach(codexLimitRows(snapshot)) { row in
                    CodexLimitBar(title: row.title, window: row.window, now: monitor.now)
                }
                Text("설치된 Codex CLI의 로그인 세션에서 직접 조회합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(monitor.codexRateLimitFailure?.userMessage ?? "Codex 사용 한도를 확인하고 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SubscriptionLimitsView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude 구독 한도")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if monitor.bridgeInstalled {
                    Button("연동 끄기") { monitor.uninstallBridge() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if let snapshot = monitor.rateLimits {
                LimitBar(title: "5시간 세션", window: snapshot.fiveHour, now: monitor.now)
                LimitBar(title: "7일 주간", window: snapshot.sevenDay, now: monitor.now)
                Text(caption(for: snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if monitor.bridgeInstalled {
                Text("연동은 켜져 있습니다. Claude Code 세션의 첫 응답이 오면 값이 채워집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Claude Code는 남은 한도를 세션 로그에 남기지 않고 상태줄에만 전달합니다. 연동을 켜면 그 값을 받아 여기에 표시합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("상태줄 연동 켜기") { monitor.installBridge() }
                Text("~/.claude/settings.json의 statusLine을 바꿉니다. 기존 설정은 백업하고, 원래 쓰던 상태줄 명령은 그대로 이어서 실행합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = monitor.bridgeMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func caption(for snapshot: RateLimitSnapshot) -> String {
        var parts: [String] = []
        if let model = snapshot.model { parts.append(model) }
        parts.append("\(relativeText(snapshot.capturedAt, now: monitor.now)) 갱신")
        return parts.joined(separator: " · ")
    }
}

private struct LimitBar: View {
    let title: String
    let window: RateLimitWindow?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(valueText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(window == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let window, !window.hasReset(asOf: now) {
                        Capsule()
                            .fill(limitTint(window.usedPercentage))
                            .frame(width: max(proxy.size.width * window.fraction, 2))
                    }
                }
            }
            .frame(height: 6)
            if let detailText {
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var valueText: String {
        guard let window else { return "정보 없음" }
        guard !window.hasReset(asOf: now) else { return "리셋됨" }
        return "\(percentText(window.remainingPercentage)) 남음"
    }

    private var detailText: String? {
        guard let window else { return nil }
        guard !window.hasReset(asOf: now) else {
            return "이전 창이 끝났습니다. 다음 응답에서 갱신됩니다."
        }
        var parts = ["\(percentText(window.usedPercentage)) 사용"]
        if let reset = resetText(window.resetsAt, now: now) { parts.append(reset) }
        return parts.joined(separator: " · ")
    }
}

private struct CodexLimitBar: View {
    let title: String
    let window: CodexRateLimitWindow?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(valueText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(window == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let window, !window.hasReset(asOf: now) {
                        Capsule()
                            .fill(limitTint(window.usedPercentage))
                            .frame(width: max(proxy.size.width * window.fraction, 2))
                    }
                }
            }
            .frame(height: 6)
            if let detailText {
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var valueText: String {
        guard let window else { return "정보 없음" }
        guard !window.hasReset(asOf: now) else { return "리셋됨" }
        return "\(percentText(window.remainingPercentage)) 남음"
    }

    private var detailText: String? {
        guard let window else { return nil }
        guard !window.hasReset(asOf: now) else {
            return "이전 창이 끝났습니다. 새로고침하면 최신 값으로 갱신됩니다."
        }
        var parts = ["\(percentText(window.usedPercentage)) 사용"]
        if let reset = resetText(window.resetsAt, now: now) { parts.append(reset) }
        return parts.joined(separator: " · ")
    }
}

private struct TotalUsageView: View {
    let usage: TokenUsage
    let recordedCost: Double
    let period: DisplayPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(period.title) 총 사용량")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(usage.total.tokenText)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("입력 \(usage.input.tokenText) · 출력 \(usage.output.tokenText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if recordedCost > 0 {
                Text("기록 비용 \(recordedCost.costText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ProviderUsageView: View {
    let provider: Provider
    let summary: ProviderSummary
    let color: Color

    var title: String {
        switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        case .opencode: "opencode"
        }
    }

    var iconSystemName: String {
        switch provider {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        case .opencode: "terminal"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: iconSystemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(summary.usage.total.tokenText)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text("입력 \(summary.usage.input.tokenText) · 출력 \(summary.usage.output.tokenText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if provider == .codex {
                Text("캐시 입력 \(summary.usage.cachedRead.tokenText) 포함")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("캐시 읽기 \(summary.usage.cachedRead.tokenText) · 생성 \(summary.usage.cachedWrite.tokenText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if provider == .opencode, summary.cost > 0 {
                Text("기록 비용 \(summary.cost.costText)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("응답 \(summary.eventCount)회")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct UsageChart: View {
    let items: [DailyUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("최근 14일")
                .font(.subheadline.weight(.semibold))
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar")
                        .font(.title2)
                    Text("집계된 사용량이 없습니다")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                    .frame(height: 140)
            } else {
                Chart(items) { item in
                    BarMark(
                        x: .value("날짜", item.day, unit: .day),
                        y: .value("토큰", item.usage.total)
                    )
                    .foregroundStyle(by: .value("도구", providerTitle(item.provider)))
                }
                .chartForegroundStyleScale([
                    "Codex": Color.green,
                    "Claude": Color.orange,
                    "opencode": Color.blue
                ])
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let tokens = value.as(Int64.self) {
                                Text(tokens.tokenText)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .frame(height: 150)
            }
        }
    }

    private func providerTitle(_ provider: Provider) -> String {
        switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        case .opencode: "opencode"
        }
    }
}

private extension Int64 {
    var tokenText: String {
        switch self {
        case 1_000_000_000...:
            String(format: "%.2fB", Double(self) / 1_000_000_000)
        case 1_000_000...:
            String(format: "%.2fM", Double(self) / 1_000_000)
        case 1_000...:
            String(format: "%.1fK", Double(self) / 1_000)
        default:
            formatted()
        }
    }
}

private extension Double {
    var costText: String {
        if self >= 10 { return String(format: "$%.2f", self) }
        if self >= 1 { return String(format: "$%.3f", self) }
        return String(format: "$%.4f", self)
    }
}
