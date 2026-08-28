public enum UsageHealthLevel: String, CaseIterable, Equatable, Sendable {
    case sun
    case cloud
    case rain
    case thunder
    case alert
    case xmark
    case unavailable

    public init(maximumUsedPercentage: Double?) {
        guard let maximumUsedPercentage, maximumUsedPercentage.isFinite else {
            self = .unavailable
            return
        }

        let used = min(max(maximumUsedPercentage, 0), 100)
        switch used {
        case ...30: self = .sun
        case ...40: self = .cloud
        case ...50: self = .rain
        case ...60: self = .thunder
        case ...80: self = .alert
        default: self = .xmark
        }
    }
}
