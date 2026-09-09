import AppKit
import Darwin
import Foundation
import IOKit

private struct SystemMetrics {
    var cpu: Double = 0
    var gpu: Double = 0
    var memory: Double = 0
    var disk: Double = 0
    var uploadBytesPerSecond: Double = 0
    var downloadBytesPerSecond: Double = 0
    var networkSampleValid = false
}

private struct NetworkCounters {
    var received: UInt64 = 0
    var sent: UInt64 = 0
}

private final class MetricsCollector {
    private var previousCPUTicks: [UInt32]?
    private var previousNetworkCounters: NetworkCounters?
    private var previousSampleTime = ProcessInfo.processInfo.systemUptime

    func sample(networkEnabled: Bool) -> SystemMetrics {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(now - previousSampleTime, 0.001)
        previousSampleTime = now

        let network: (upload: Double, download: Double, isValid: Bool)
        if networkEnabled {
            network = sampleNetwork(elapsed: elapsed)
        } else {
            // Start a fresh delta window when network monitoring is enabled
            // again, rather than reporting the bytes accumulated while hidden.
            previousNetworkCounters = nil
            network = (0, 0, false)
        }

        return SystemMetrics(
            cpu: sampleCPU(),
            gpu: sampleGPU(),
            memory: sampleMemory(),
            disk: sampleDisk(),
            uploadBytesPerSecond: network.upload,
            downloadBytesPerSecond: network.download,
            networkSampleValid: network.isValid
        )
    }

    private func sampleCPU() -> Double {
        var loadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &loadInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let ticks: [UInt32] = [
            loadInfo.cpu_ticks.0,
            loadInfo.cpu_ticks.1,
            loadInfo.cpu_ticks.2,
            loadInfo.cpu_ticks.3
        ]

        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks, previous.count == ticks.count else {
            return 0
        }

        let deltas = zip(ticks, previous).map { UInt64($0) - UInt64($1) }
        let total = deltas.reduce(0, +)
        let idle = deltas[Int(CPU_STATE_IDLE)] + deltas[Int(CPU_STATE_NICE)]

        guard total > 0 else { return 0 }
        return clamp(Double(total - min(idle, total)) / Double(total))
    }

    private func sampleMemory() -> Double {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return 0
        }

        let totalPages = ProcessInfo.processInfo.physicalMemory / UInt64(pageSize)
        guard totalPages > 0 else { return 0 }

        // Inactive and speculative pages can be reclaimed by macOS, so count
        // them as available rather than presenting an inflated "used" value.
        let availablePages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
        let usedPages = totalPages > availablePages ? totalPages - availablePages : 0

        return clamp(Double(usedPages) / Double(totalPages))
    }

    private func sampleDisk() -> Double {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
            guard
                let total = (attributes[.systemSize] as? NSNumber)?.uint64Value,
                let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value,
                total > 0
            else {
                return 0
            }

            let used = total > free ? total - free : 0
            return clamp(Double(used) / Double(total))
        } catch {
            return 0
        }
    }

    private func sampleGPU() -> Double {
        var iterator: io_iterator_t = 0
        guard
            let matching = IOServiceMatching("IOAccelerator"),
            IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var highestUtilization = 0.0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard
                let property = IORegistryEntryCreateCFProperty(
                    service,
                    "PerformanceStatistics" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? [String: Any]
            else {
                continue
            }

            // This registry property is available on current Apple GPU and
            // Intel GPU drivers. Prefer the device value, with fallbacks for
            // drivers that expose only renderer or tiler utilization.
            for key in ["Device Utilization %", "Renderer Utilization %", "Tiler Utilization %"] {
                if let value = property[key] as? NSNumber {
                    highestUtilization = max(highestUtilization, value.doubleValue / 100)
                }
            }
        }

        return clamp(highestUtilization)
    }

    private func sampleNetwork(
        elapsed: TimeInterval
    ) -> (upload: Double, download: Double, isValid: Bool) {
        let counters = readNetworkCounters()
        defer { previousNetworkCounters = counters }

        guard let previous = previousNetworkCounters else {
            return (0, 0, false)
        }

        let received = counters.received >= previous.received
            ? counters.received - previous.received
            : 0
        let sent = counters.sent >= previous.sent
            ? counters.sent - previous.sent
            : 0

        return (
            upload: Double(sent) / elapsed,
            download: Double(received) / elapsed,
            isValid: true
        )
    }

    private func readNetworkCounters() -> NetworkCounters {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return NetworkCounters()
        }
        defer { freeifaddrs(addresses) }

        var counters = NetworkCounters()
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let interface = current {
            let flags = interface.pointee.ifa_flags
            let name = String(cString: interface.pointee.ifa_name)
            let isVirtual = name.hasPrefix("utun")
                || name.hasPrefix("awdl")
                || name.hasPrefix("llw")
                || name.hasPrefix("bridge")

            if (flags & UInt32(IFF_UP)) != 0,
               (flags & UInt32(IFF_RUNNING)) != 0,
               (flags & UInt32(IFF_LOOPBACK)) == 0,
               !isVirtual,
               let address = interface.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                counters.received += UInt64(data.pointee.ifi_ibytes)
                counters.sent += UInt64(data.pointee.ifi_obytes)
            }

            current = interface.pointee.ifa_next
        }

        return counters
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

@MainActor
private final class StatusItemView: NSView {
    private struct RateDisplay {
        let value: String
        let unit: String

        var accessibilityText: String { "\(value) \(unit)" }
    }

    private var metrics = SystemMetrics()
    private var networkEnabled = true
    private var networkVisibilityProgress: CGFloat = 1
    private var networkFadingOut = false
    private var displayedRingValues = [0.0, 0.0, 0.0]
    private var animationStartValues = [0.0, 0.0, 0.0]
    private var animationTargetValues = [0.0, 0.0, 0.0]
    private var animationStartUptime: TimeInterval = 0
    private var animationTimer: Timer?
    private let ringColors: [NSColor] = [
        RingPalette.cpu,
        RingPalette.gpu,
        RingPalette.memory
    ]
    private let ringRadii: [CGFloat] = [8.5, 5.9, 3.3]
    private let ringLineWidth: CGFloat = 2.0
    private let animationDuration: TimeInterval = 0.36

    var onClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func update(
        with metrics: SystemMetrics,
        enabledRings: [Bool],
        networkEnabled: Bool
    ) {
        var nextMetrics = metrics
        if !metrics.networkSampleValid {
            // Keep the last real rate while a new counter baseline is being
            // established, instead of showing a misleading 0 B/s.
            nextMetrics.uploadBytesPerSecond = self.metrics.uploadBytesPerSecond
            nextMetrics.downloadBytesPerSecond = self.metrics.downloadBytesPerSecond
        }
        self.metrics = nextMetrics
        self.networkEnabled = networkEnabled

        animationStartValues = displayedRingValues
        animationTargetValues = [nextMetrics.cpu, nextMetrics.gpu, nextMetrics.memory]
            .enumerated()
            .map { enabledRings.indices.contains($0.offset) && enabledRings[$0.offset] ? $0.element : 0 }
        animationStartUptime = ProcessInfo.processInfo.systemUptime
        animationTimer?.invalidate()

        let hasRingChange = zip(animationStartValues, animationTargetValues)
            .contains { abs($0 - $1) > 0.0001 }
        if hasRingChange {
            let timer = Timer(
                timeInterval: 1.0 / 30.0,
                target: self,
                selector: #selector(animateRings(_:)),
                userInfo: nil,
                repeats: true
            )
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else {
            displayedRingValues = animationTargetValues
        }

        let accessibilityValue: String
        if networkEnabled && nextMetrics.networkSampleValid {
            accessibilityValue = String(
                format: "CPU %.0f%%, GPU %.0f%%, MEM %.0f%%, SSD %.0f%%, upload %@, download %@",
                nextMetrics.cpu * 100,
                nextMetrics.gpu * 100,
                nextMetrics.memory * 100,
                nextMetrics.disk * 100,
                Self.formatRate(nextMetrics.uploadBytesPerSecond).accessibilityText,
                Self.formatRate(nextMetrics.downloadBytesPerSecond).accessibilityText
            )
        } else {
            accessibilityValue = String(
                format: "CPU %.0f%%, GPU %.0f%%, MEM %.0f%%, SSD %.0f%%",
                nextMetrics.cpu * 100,
                nextMetrics.gpu * 100,
                nextMetrics.memory * 100,
                nextMetrics.disk * 100
            )
        }
        setAccessibilityValue(accessibilityValue)
        needsDisplay = true
    }

    func setNetworkVisibility(progress: CGFloat, fadingOut: Bool) {
        networkVisibilityProgress = min(max(progress, 0), 1)
        networkFadingOut = fadingOut
        needsDisplay = true
    }

    @objc private func animateRings(_ timer: Timer) {
        let elapsed = ProcessInfo.processInfo.systemUptime - animationStartUptime
        let linearProgress = min(max(elapsed / animationDuration, 0), 1)
        // Smoothstep gives the ring a gentle start and finish without a
        // permanently running display timer.
        let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)

        displayedRingValues = zip(animationStartValues, animationTargetValues).map {
            $0 + ($1 - $0) * progress
        }
        needsDisplay = true

        if linearProgress >= 1 {
            displayedRingValues = animationTargetValues
            timer.invalidate()
            animationTimer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let center = NSPoint(
            x: StatusItemLayout.ringCenterX,
            y: StatusItemLayout.ringCenterY
        )
        let values = displayedRingValues

        for (index, radius) in ringRadii.enumerated() {
            let path = NSBezierPath()
            path.lineWidth = ringLineWidth
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 0,
                endAngle: 360,
                clockwise: false
            )
            let trackColor = ringColors[index].blended(withFraction: 0.78, of: .black)
                ?? ringColors[index].withAlphaComponent(0.22)
            trackColor.setStroke()
            path.stroke()
        }

        for (index, radius) in ringRadii.enumerated() {
            let progress = min(max(values[index], 0), 0.9999)
            guard progress > 0 else { continue }

            let path = NSBezierPath()
            path.lineWidth = ringLineWidth
            path.lineCapStyle = .round
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - CGFloat(progress * 360),
                clockwise: true
            )
            ringColors[index].setStroke()
            path.stroke()
        }

        guard networkVisibilityProgress > 0 else { return }

        let attributes = Self.networkAttributes()
        drawRate(
            Self.formatRate(metrics.uploadBytesPerSecond),
            arrow: "↑",
            y: 9.2,
            attributes: attributes,
            visibilityProgress: networkVisibilityProgress,
            fadingOut: networkFadingOut
        )
        drawRate(
            Self.formatRate(metrics.downloadBytesPerSecond),
            arrow: "↓",
            y: -1.1,
            attributes: attributes,
            visibilityProgress: networkVisibilityProgress,
            fadingOut: networkFadingOut
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    private func drawRate(
        _ rate: RateDisplay,
        arrow: String,
        y: CGFloat,
        attributes: [NSAttributedString.Key: Any],
        visibilityProgress: CGFloat,
        fadingOut: Bool
    ) {
        let valueWidth = (rate.value as NSString).size(withAttributes: attributes).width
        let valueX = StatusItemLayout.unitX - StatusItemLayout.unitGap - valueWidth

        arrow.draw(
            at: NSPoint(x: StatusItemLayout.textStartX, y: y),
            withAttributes: Self.networkAttributes(
                basedOn: attributes,
                alpha: Self.networkTextAlpha(
                    at: StatusItemLayout.textStartX,
                    visibilityProgress: visibilityProgress,
                    fadingOut: fadingOut
                )
            )
        )

        rate.value.draw(
            at: NSPoint(x: valueX, y: y),
            withAttributes: Self.networkAttributes(
                basedOn: attributes,
                alpha: Self.networkTextAlpha(
                    at: valueX,
                    visibilityProgress: visibilityProgress,
                    fadingOut: fadingOut
                )
            )
        )
        rate.unit.draw(
            at: NSPoint(x: StatusItemLayout.unitX, y: y),
            withAttributes: Self.networkAttributes(
                basedOn: attributes,
                alpha: Self.networkTextAlpha(
                    at: StatusItemLayout.unitX,
                    visibilityProgress: visibilityProgress,
                    fadingOut: fadingOut
                )
            )
        )
    }

    private static func networkAttributes(
        basedOn attributes: [NSAttributedString.Key: Any],
        alpha: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        var adjusted = attributes
        let baseColor = (attributes[.foregroundColor] as? NSColor) ?? NSColor.labelColor
        adjusted[.foregroundColor] = baseColor.withAlphaComponent(min(max(alpha, 0), 1))
        return adjusted
    }

    private static func networkTextAlpha(
        at x: CGFloat,
        visibilityProgress: CGFloat,
        fadingOut: Bool
    ) -> CGFloat {
        let contentWidth = StatusItemLayout.fullWidth - StatusItemLayout.textStartX
        let normalizedX = min(max((x - StatusItemLayout.textStartX) / contentWidth, 0), 1)
        let feather: CGFloat = 0.22

        if fadingOut {
            let hideProgress = 1 - visibilityProgress
            let edge = hideProgress - feather
            return smoothStep((normalizedX - edge) / feather)
        }

        return smoothStep((visibilityProgress - normalizedX) / feather)
    }

    private static func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func formatRate(_ bytesPerSecond: Double) -> RateDisplay {
        let value = max(bytesPerSecond, 0)
        let kilo = 1000.0
        if value < kilo {
            return RateDisplay(value: String(format: "%.0f", floor(value)), unit: "B/s")
        }
        if value < kilo * kilo {
            return RateDisplay(value: formatScaledRate(value / kilo), unit: "K/s")
        }
        if value < kilo * kilo * kilo {
            return RateDisplay(value: formatScaledRate(value / (kilo * kilo)), unit: "M/s")
        }
        return RateDisplay(
            value: formatScaledRate(value / (kilo * kilo * kilo)),
            unit: "G/s"
        )
    }

    private static func formatScaledRate(_ value: Double) -> String {
        if value < 100 {
            // Truncate instead of round so 99.9 remains four characters and
            // never pushes the unit column to the right.
            return String(format: "%.1f", floor(value * 10) / 10)
        }
        return String(format: "%.0f", floor(value))
    }

    private static func networkAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
    }
}

@MainActor
private enum RingPalette {
    // Apple’s documented Activity ring colors, reused here as a visual
    // reference for a private prototype rather than as Apple Activity data.
    static let cpu = NSColor(calibratedRed: 250 / 255, green: 17 / 255, blue: 79 / 255, alpha: 1)
    static let gpu = NSColor(calibratedRed: 166 / 255, green: 255 / 255, blue: 0, alpha: 1)
    static let memory = NSColor(calibratedRed: 0, green: 255 / 255, blue: 246 / 255, alpha: 1)
}

private enum StatusItemLayout {
    // Keep the full network block stable, but reclaim its space when hidden.
    static let fullWidth: CGFloat = 88
    static let ringOnlyWidth: CGFloat = 26
    static let height: CGFloat = 22
    // Calibrated against the center-to-center gap from the arrow to a
    // two-digit, one-decimal value such as "12.3".
    static let ringCenterX: CGFloat = 13
    // The two-line network block sits a touch lower optically than the view's
    // mathematical midpoint, so the rings follow that visual center.
    static let ringCenterY: CGFloat = 10.5
    static let textStartX: CGFloat = 29
    static let unitX: CGFloat = 67
    static let unitGap: CGFloat = 3

    static func width(networkEnabled: Bool) -> CGFloat {
        networkEnabled ? fullWidth : ringOnlyWidth
    }

    static func width(forNetworkProgress progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return ringOnlyWidth + (fullWidth - ringOnlyWidth) * clamped
    }
}

private enum MenuLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var nativeName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    var languageMenuTitle: String {
        switch self {
        case .simplifiedChinese: return "语言"
        case .traditionalChinese: return "語言"
        case .english: return "Language"
        }
    }

    var updateFrequencyTitle: String {
        switch self {
        case .simplifiedChinese: return "数据更新频率"
        case .traditionalChinese: return "資料更新頻率"
        case .english: return "Update Frequency"
        }
    }

    var networkTitle: String {
        switch self {
        case .simplifiedChinese: return "网速"
        case .traditionalChinese: return "網速"
        case .english: return "Network"
        }
    }

    var quitTitle: String {
        switch self {
        case .simplifiedChinese: return "退出"
        case .traditionalChinese: return "結束"
        case .english: return "Quit"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .simplifiedChinese: return "RingMonitor 系统监控"
        case .traditionalChinese: return "RingMonitor 系統監控"
        case .english: return "RingMonitor system monitor"
        }
    }

    func secondsTitle(_ seconds: Int) -> String {
        switch self {
        case .simplifiedChinese, .traditionalChinese:
            return "\(seconds) 秒"
        case .english:
            return seconds == 1 ? "1 second" : "\(seconds) seconds"
        }
    }
}

@MainActor
private final class MenuBarController: NSObject {
    private enum NetworkTransitionPhase: Equatable {
        case hidingContent
        case shrinkingWidth
        case expandingWidth
        case waitingForSample
        case revealingContent
    }

    private let statusItem: NSStatusItem
    private let statusView: StatusItemView
    private let collector = MetricsCollector()
    private let menu = NSMenu()
    private let frequencyMenu = NSMenu()
    private var timer: Timer?
    private var updateInterval: TimeInterval
    private var ringEnabled: [Bool]
    private var networkEnabled: Bool
    private var ringMenuItems: [NSMenuItem] = []
    private var currentLanguage: MenuLanguage
    private var frequencyItem: NSMenuItem?
    private var networkMenuItem: NSMenuItem?
    private var languageItem: NSMenuItem?
    private var quitItem: NSMenuItem?
    private var frequencyMenuItems: [NSMenuItem] = []
    private var languageMenuItems: [NSMenuItem] = []
    private let languageMenu = NSMenu()
    private var networkTransitionTimer: Timer?
    private var networkTransitionPhase: NetworkTransitionPhase?
    private var networkTransitionStartUptime: TimeInterval = 0
    private var networkTransitionDuration: TimeInterval = 0
    private var networkTransitionStartValue: CGFloat = 0
    private var networkTransitionTargetValue: CGFloat = 0
    private var networkWidthProgress: CGFloat = 1
    private var networkContentProgress: CGFloat = 1
    private var networkSampleReady = true

    private static let updateIntervalKey = "updateInterval"
    private static let ringVisibilityKey = "ringVisibility"
    private static let networkVisibilityKey = "networkVisibility"
    private static let languageKey = "language"
    private static let defaultRingVisibility = [true, true, true]
    private static let defaultNetworkVisibility = true
    private static let supportedIntervals: [TimeInterval] = [1, 5, 10, 30, 60]

    override init() {
        let savedInterval = UserDefaults.standard.double(forKey: Self.updateIntervalKey)
        updateInterval = Self.supportedIntervals.contains(savedInterval) ? savedInterval : 5
        ringEnabled = Self.loadRingVisibility()
        networkEnabled = Self.loadNetworkVisibility()
        currentLanguage = Self.loadLanguage()
        networkWidthProgress = networkEnabled ? 1 : 0
        networkContentProgress = networkEnabled ? 1 : 0

        let initialWidth = StatusItemLayout.width(networkEnabled: networkEnabled)
        statusItem = NSStatusBar.system.statusItem(withLength: initialWidth)
        statusView = StatusItemView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: initialWidth,
                height: StatusItemLayout.height
            )
        )

        super.init()

        statusItem.length = initialWidth
        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
        }
        statusView.onClick = { [weak self] in self?.showMenu() }
        statusView.setAccessibilityElement(true)
        statusView.setAccessibilityRole(.button)
        statusView.setAccessibilityLabel(currentLanguage.accessibilityLabel)
        statusView.setNetworkVisibility(progress: networkContentProgress, fadingOut: false)

        buildMenu()
        sampleAndUpdate()
        scheduleTimer()
    }

    private func buildMenu() {
        menu.autoenablesItems = false

        ringMenuItems = [
            makeLegendItem(title: "CPU", color: RingPalette.cpu, index: 0),
            makeLegendItem(title: "GPU", color: RingPalette.gpu, index: 1),
            makeLegendItem(title: "MEM", color: RingPalette.memory, index: 2)
        ]
        ringMenuItems.forEach { menu.addItem($0) }

        let networkMenuItem = makeNetworkItem()
        self.networkMenuItem = networkMenuItem
        menu.addItem(networkMenuItem)
        menu.addItem(.separator())

        let frequencyMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        frequencyMenuItem.submenu = frequencyMenu
        frequencyItem = frequencyMenuItem
        menu.addItem(frequencyMenuItem)

        for interval in Self.supportedIntervals {
            let item = NSMenuItem(
                title: "",
                action: #selector(updateIntervalFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = interval
            frequencyMenu.addItem(item)
            frequencyMenuItems.append(item)
        }
        refreshFrequencySelection()

        let languageMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        languageMenuItem.submenu = languageMenu
        languageItem = languageMenuItem
        menu.addItem(languageMenuItem)

        for language in MenuLanguage.allCases {
            let item = NSMenuItem(title: language.nativeName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            languageMenu.addItem(item)
            languageMenuItems.append(item)
        }

        menu.addItem(.separator())
        let quitMenuItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self
        quitItem = quitMenuItem
        menu.addItem(quitMenuItem)
        refreshLocalizedMenu()
    }

    private func makeLegendItem(title: String, color: NSColor, index: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleRing(_:)), keyEquivalent: "")
        item.target = self
        item.tag = index
        item.state = ringEnabled[index] ? .on : .off
        let attributedTitle = NSMutableAttributedString()
        attributedTitle.append(NSAttributedString(
            string: "● ",
            attributes: [
                .font: NSFont.menuFont(ofSize: 13),
                .foregroundColor: color
            ]
        ))
        attributedTitle.append(NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        item.attributedTitle = attributedTitle
        // Keep legend rows visually saturated. A disabled NSMenuItem causes
        // AppKit to dim the colored dot along with the label.
        item.isEnabled = true
        return item
    }

    private func makeNetworkItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(toggleNetwork(_:)), keyEquivalent: "")
        item.target = self
        item.state = networkEnabled ? .on : .off
        refreshNetworkTitle(for: item)
        return item
    }

    private func refreshNetworkTitle(for item: NSMenuItem? = nil) {
        guard let item = item ?? networkMenuItem else { return }

        let font = NSFont.menuFont(ofSize: 13)
        let attributedTitle = NSMutableAttributedString()
        attributedTitle.append(NSAttributedString(
            string: "● ",
            attributes: [
                .font: font,
                // Match the label color so the network row follows the same
                // alignment pattern without introducing a fourth ring color.
                .foregroundColor: NSColor.labelColor
            ]
        ))
        attributedTitle.append(NSAttributedString(
            string: currentLanguage.networkTitle,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        ))
        item.attributedTitle = attributedTitle
    }

    private static func loadRingVisibility() -> [Bool] {
        guard
            let stored = UserDefaults.standard.array(forKey: ringVisibilityKey),
            stored.count == defaultRingVisibility.count
        else {
            return defaultRingVisibility
        }

        let values = stored.compactMap { ($0 as? NSNumber)?.boolValue }
        return values.count == defaultRingVisibility.count ? values : defaultRingVisibility
    }

    private static func loadNetworkVisibility() -> Bool {
        guard UserDefaults.standard.object(forKey: networkVisibilityKey) != nil else {
            return defaultNetworkVisibility
        }
        return UserDefaults.standard.bool(forKey: networkVisibilityKey)
    }

    private static func loadLanguage() -> MenuLanguage {
        if
            let stored = UserDefaults.standard.string(forKey: languageKey),
            let language = MenuLanguage(rawValue: stored)
        {
            return language
        }

        for identifier in Locale.preferredLanguages {
            let normalized = identifier.lowercased()
            if normalized.contains("hant")
                || normalized.hasPrefix("zh-tw")
                || normalized.hasPrefix("zh-hk")
                || normalized.hasPrefix("zh-mo")
            {
                return .traditionalChinese
            }
            if normalized.hasPrefix("en") {
                return .english
            }
            if normalized.hasPrefix("zh") {
                return .simplifiedChinese
            }
        }

        return .simplifiedChinese
    }

    private func refreshLocalizedMenu() {
        frequencyItem?.title = currentLanguage.updateFrequencyTitle
        refreshNetworkTitle()
        languageItem?.title = currentLanguage.languageMenuTitle
        quitItem?.title = currentLanguage.quitTitle
        statusView.setAccessibilityLabel(currentLanguage.accessibilityLabel)

        for (index, item) in frequencyMenuItems.enumerated() {
            guard index < Self.supportedIntervals.count else { continue }
            item.title = currentLanguage.secondsTitle(Int(Self.supportedIntervals[index]))
        }

        refreshFrequencySelection()
        refreshNetworkSelection()
        refreshLanguageSelection()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let nextTimer = Timer(
            timeInterval: updateInterval,
            target: self,
            selector: #selector(timerDidFire),
            userInfo: nil,
            repeats: true
        )
        nextTimer.tolerance = max(0.1, updateInterval * 0.1)
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    private func sampleAndUpdate() {
        let metrics = collector.sample(networkEnabled: networkEnabled)
        statusView.update(
            with: metrics,
            enabledRings: ringEnabled,
            networkEnabled: networkEnabled
        )

        guard networkEnabled, metrics.networkSampleValid, !networkSampleReady else { return }

        networkSampleReady = true
        if networkTransitionPhase == .waitingForSample {
            beginNetworkPhase(
                .revealingContent,
                from: networkContentProgress,
                to: 1,
                duration: 0.12,
                fadingOut: false
            )
        }
    }

    private func updateStatusItemLayout() {
        let width = StatusItemLayout.width(forNetworkProgress: networkWidthProgress)
        statusItem.length = width
        if let button = statusItem.button {
            statusView.frame = button.bounds
        }
    }

    private func beginNetworkPhase(
        _ phase: NetworkTransitionPhase,
        from: CGFloat,
        to: CGFloat,
        duration: TimeInterval,
        fadingOut: Bool
    ) {
        networkTransitionTimer?.invalidate()
        networkTransitionPhase = phase
        networkTransitionStartValue = from
        networkTransitionTargetValue = to
        networkTransitionStartUptime = ProcessInfo.processInfo.systemUptime
        networkTransitionDuration = duration

        switch phase {
        case .hidingContent, .revealingContent:
            networkContentProgress = from
            statusView.setNetworkVisibility(progress: from, fadingOut: fadingOut)
        case .shrinkingWidth, .expandingWidth:
            networkWidthProgress = from
            updateStatusItemLayout()
        case .waitingForSample:
            break
        }

        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(animateNetworkTransition(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        networkTransitionTimer = timer
    }

    private func waitForNetworkSample() {
        networkTransitionTimer?.invalidate()
        networkTransitionTimer = nil
        networkTransitionPhase = .waitingForSample
    }

    private func finishNetworkTransition() {
        networkTransitionTimer?.invalidate()
        networkTransitionTimer = nil
        networkTransitionPhase = nil

        let finalProgress: CGFloat = networkEnabled ? 1 : 0
        networkWidthProgress = finalProgress
        networkContentProgress = finalProgress
        updateStatusItemLayout()
        statusView.setNetworkVisibility(progress: finalProgress, fadingOut: false)
    }

    @objc private func animateNetworkTransition(_ timer: Timer) {
        guard let phase = networkTransitionPhase else {
            timer.invalidate()
            networkTransitionTimer = nil
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - networkTransitionStartUptime
        let linearProgress = min(max(elapsed / networkTransitionDuration, 0), 1)
        let easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        let value = networkTransitionStartValue
            + (networkTransitionTargetValue - networkTransitionStartValue) * CGFloat(easedProgress)

        switch phase {
        case .hidingContent:
            networkContentProgress = value
            statusView.setNetworkVisibility(progress: value, fadingOut: true)
        case .shrinkingWidth, .expandingWidth:
            networkWidthProgress = value
            updateStatusItemLayout()
        case .revealingContent:
            networkContentProgress = value
            statusView.setNetworkVisibility(progress: value, fadingOut: false)
        case .waitingForSample:
            return
        }

        guard linearProgress >= 1 else { return }

        switch phase {
        case .hidingContent:
            beginNetworkPhase(
                .shrinkingWidth,
                from: networkWidthProgress,
                to: 0,
                duration: 0.18,
                fadingOut: true
            )
        case .shrinkingWidth:
            finishNetworkTransition()
        case .expandingWidth:
            if networkSampleReady {
                beginNetworkPhase(
                    .revealingContent,
                    from: networkContentProgress,
                    to: 1,
                    duration: 0.12,
                    fadingOut: false
                )
            } else {
                waitForNetworkSample()
            }
        case .revealingContent:
            finishNetworkTransition()
        case .waitingForSample:
            break
        }
    }

    private func showMenu() {
        let isDarkMode = UserDefaults.standard
            .string(forKey: "AppleInterfaceStyle")?
            .lowercased() == "dark"
        let appearanceName: NSAppearance.Name = isDarkMode ? .darkAqua : .aqua
        let appearance = NSAppearance(named: appearanceName) ?? NSApp.effectiveAppearance
        menu.appearance = appearance
        frequencyMenu.appearance = appearance
        languageMenu.appearance = appearance

        menu.popUp(
            positioning: nil,
            // NSMenu treats this as the menu's top-left corner when no item
            // is supplied. Align it with the status item's leading edge,
            // rather than placing the menu's left edge at the ring center.
            at: NSPoint(x: statusView.bounds.minX, y: statusView.bounds.minY - 10),
            in: statusView
        )
    }

    private func refreshFrequencySelection() {
        for item in frequencyMenu.items {
            guard let value = item.representedObject as? NSNumber else { continue }
            item.state = value.doubleValue == updateInterval ? .on : .off
        }
    }

    private func refreshNetworkSelection() {
        networkMenuItem?.state = networkEnabled ? .on : .off
    }

    private func refreshRingSelection() {
        for (index, item) in ringMenuItems.enumerated() where ringEnabled.indices.contains(index) {
            item.state = ringEnabled[index] ? .on : .off
        }
    }

    private func refreshLanguageSelection() {
        for item in languageMenuItems {
            guard
                let rawValue = item.representedObject as? String,
                let language = MenuLanguage(rawValue: rawValue)
            else { continue }
            item.state = language == currentLanguage ? .on : .off
        }
    }

    @objc private func timerDidFire() {
        sampleAndUpdate()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        showMenu()
    }

    @objc private func toggleRing(_ sender: NSMenuItem) {
        let index = sender.tag
        guard ringEnabled.indices.contains(index) else { return }

        ringEnabled[index].toggle()
        UserDefaults.standard.set(ringEnabled.map { NSNumber(value: $0) }, forKey: Self.ringVisibilityKey)
        refreshRingSelection()
        sampleAndUpdate()
    }

    @objc private func toggleNetwork(_ sender: NSMenuItem) {
        networkEnabled.toggle()
        UserDefaults.standard.set(networkEnabled, forKey: Self.networkVisibilityKey)
        refreshNetworkSelection()
        sampleAndUpdate()

        if networkEnabled {
            networkSampleReady = false
            networkContentProgress = 0
            statusView.setNetworkVisibility(progress: 0, fadingOut: false)
            beginNetworkPhase(
                .expandingWidth,
                from: networkWidthProgress,
                to: 1,
                duration: 0.18,
                fadingOut: false
            )
        } else {
            networkSampleReady = false
            beginNetworkPhase(
                .hidingContent,
                from: networkContentProgress,
                to: 0,
                duration: 0.12,
                fadingOut: true
            )
        }
    }

    @objc private func updateIntervalFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        updateInterval = value.doubleValue
        UserDefaults.standard.set(updateInterval, forKey: Self.updateIntervalKey)
        refreshFrequencySelection()
        scheduleTimer()
        sampleAndUpdate()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let language = MenuLanguage(rawValue: rawValue)
        else { return }

        currentLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
        refreshLocalizedMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()
    }
}

let application = NSApplication.shared
private let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
