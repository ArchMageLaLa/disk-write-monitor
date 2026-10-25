import SwiftUI
import AppKit
import Darwin

// MARK: - 数据模型

struct WriteSample: Identifiable {
    let id = UUID()
    let time: Date
    let rate: Double
}

struct SmartResult {
    var units: Int
    var model: String
    var temp: Int?
    var used: Int?
    var media: Int?
}

struct ProcWrite: Identifiable {
    let id: String
    let name: String
    let bytes: UInt64
}

enum Palette {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.063)
    static let surface = Color(red: 0.078, green: 0.102, blue: 0.125)
    static let text = Color(red: 0.914, green: 0.929, blue: 0.949)
    static let muted = Color(red: 0.541, green: 0.580, blue: 0.651)
    static let accent = Color(red: 0.220, green: 0.741, blue: 0.973)
    static let ok = Color(red: 0.204, green: 0.827, blue: 0.600)
    static let warn = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let bad = Color(red: 0.973, green: 0.443, blue: 0.443)
}

// MARK: - 采集器

@MainActor
final class WriteMonitor: ObservableObject {
    @Published var rate: Double = 0
    @Published var peak: Double = 0
    @Published var totalGB: Double = 0
    @Published var sessionGB: Double = 0
    @Published var temperature: Int?
    @Published var model: String = "正在读取硬盘…"
    @Published var device: String = "/dev/disk0"
    @Published var errorText: String?
    @Published var updated: Date = Date()
    @Published var history: [WriteSample] = []
    @Published var isPaused = false
    @Published var topProcesses: [ProcWrite] = []

    private var timer: Timer?
    private var busy = false
    private var previousUnits: Int?
    private var previousTime: Date?
    private var firstUnits: Int?
    private var consecutiveFailures = 0
    private var procPreviousBytes: [pid_t: UInt64] = [:]
    private var procNames: [pid_t: String] = [:]
    private var procCumulative: [String: UInt64] = [:]

    static let unitBytes = 512_000.0

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !isPaused, !busy else { return }
        busy = true
        let now = Date()
        DispatchQueue.global(qos: .utility).async {
            let outcome = Self.readSmart()
            let processes = Self.snapshotProcesses()
            DispatchQueue.main.async { [weak self] in
                self?.apply(outcome, at: now)
                self?.applyProcesses(processes, at: now)
                self?.busy = false
            }
        }
    }

    // MARK: 进程级写入

    private func applyProcesses(_ snapshot: [pid_t: UInt64], at now: Date) {
        for (pid, written) in snapshot {
            var name = procNames[pid] ?? Self.processName(pid)
            if name.hasPrefix("pid ") { name = Self.processName(pid) }
            procNames[pid] = name

            // 名字还没解析出来时先只记基线，下一轮再累计，
            // 避免留下永久的 "pid 12345" 条目
            if name.hasPrefix("pid ") {
                procPreviousBytes[pid] = written
                continue
            }

            if let previous = procPreviousBytes[pid], written >= previous {
                let delta = written - previous
                if delta > 0 {
                    procCumulative[name, default: 0] += delta
                }
            }
            procPreviousBytes[pid] = written
        }

        let live = Set(snapshot.keys)
        for pid in Array(procPreviousBytes.keys) where !live.contains(pid) {
            procPreviousBytes[pid] = nil
            procNames[pid] = nil
        }

        // 进程退出后保留它的累计值；只有极端多条目时才裁剪，防止长时间运行内存膨胀
        if procCumulative.count > 1200 {
            let keep = Set(procCumulative.sorted { $0.value > $1.value }.prefix(1000).map { $0.key })
            for name in Array(procCumulative.keys) where !keep.contains(name) {
                procCumulative[name] = nil
            }
        }

        topProcesses = procCumulative
            .compactMap { name, total -> ProcWrite? in
                guard total > 0 else { return nil }
                return ProcWrite(id: name, name: name, bytes: total)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    nonisolated static func snapshotProcesses() -> [pid_t: UInt64] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bufferSize = Int32(pids.count * MemoryLayout<pid_t>.size)
        let count = proc_listallpids(&pids, bufferSize)
        guard count > 0 else { return [:] }

        var result: [pid_t: UInt64] = [:]
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            if status == 0, info.ri_diskio_byteswritten > 0 {
                result[pid] = info.ri_diskio_byteswritten
            }
        }
        return result
    }

    nonisolated static func processName(_ pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if length > 0, let path = String(validatingUTF8: pathBuffer) {
            return (path as NSString).lastPathComponent
        }
        var nameBuffer = [CChar](repeating: 0, count: 128)
        if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0,
           let name = String(validatingUTF8: nameBuffer) {
            return name
        }
        return "pid \(pid)"
    }

    private func apply(_ outcome: Result<SmartResult, Error>, at now: Date) {
        switch outcome {
        case .failure(let error):
            consecutiveFailures += 1
            // 硬盘忙时 smartctl 偶尔会读失败，连续失败 3 次才提示
            if consecutiveFailures >= 3 {
                errorText = error.localizedDescription
            }
            updated = now

        case .success(let result):
            consecutiveFailures = 0
            errorText = nil
            if !result.model.isEmpty { model = result.model }
            temperature = result.temp
            if firstUnits == nil { firstUnits = result.units }

            if let prev = previousUnits, let prevTime = previousTime {
                let delta = max(0, result.units - prev)
                let dt = max(0.2, now.timeIntervalSince(prevTime))
                rate = Double(delta) * Self.unitBytes / 1_000_000.0 / dt
                peak = max(peak, rate)
                history.append(WriteSample(time: now, rate: rate))
            } else {
                history.append(WriteSample(time: now, rate: 0))
            }

            previousUnits = result.units
            previousTime = now
            totalGB = Double(result.units) * Self.unitBytes / 1e9
            sessionGB = Double(result.units - (firstUnits ?? result.units)) * Self.unitBytes / 1e9
            if history.count > 300 { history.removeFirst(history.count - 300) }
            updated = now
        }
    }

    // MARK: smartctl

    nonisolated static func smartctlURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "smartctl", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for path in ["/usr/local/sbin/smartctl", "/opt/homebrew/sbin/smartctl", "/usr/local/bin/smartctl"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    nonisolated static func readSmart(device: String = "/dev/disk0") -> Result<SmartResult, Error> {
        guard let tool = smartctlURL() else {
            return .failure(NSError(domain: "DiskWrites", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "找不到 smartctl，请重新安装本应用。"
            ]))
        }

        var lastText = ""
        var launchError: String?

        // macOS 上 smartctl 偶发 IOCreatePlugInInterfaceForService failed，
        // 稍等重试即可成功，最多试 3 次。
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
            let task = Process()
            task.executableURL = tool
            task.arguments = ["-x", device]
            let out = Pipe()
            task.standardOutput = out
            task.standardError = out

            do {
                try task.run()
            } catch {
                launchError = "无法启动 smartctl：\(error.localizedDescription)"
                continue
            }

            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            lastText = text

            if let unitsText = match(#"^\s*Data Units Written:\s+([0-9,]+)"#, in: text),
               let units = Int(unitsText.replacingOccurrences(of: ",", with: "")) {
                return .success(SmartResult(
                    units: units,
                    model: match(#"^\s*Model Number:\s+(.+?)\s*$"#, in: text) ?? "",
                    temp: match(#"^\s*Temperature:\s+([0-9]+)"#, in: text).flatMap(Int.init),
                    used: match(#"^\s*Percentage Used:\s+([0-9]+)"#, in: text).flatMap(Int.init),
                    media: match(#"^\s*Media and Data Integrity Errors:\s+([0-9]+)"#, in: text).flatMap(Int.init)
                ))
            }
        }

        if ProcessInfo.processInfo.environment["DW_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(("--- smartctl output ---\n" + lastText + "\n--- end ---\n").utf8))
        }

        let lines = lastText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)
        let snippet = (lines.prefix(1) + lines.suffix(2)).joined(separator: " | ")
        let message = launchError ?? "读不到这块硬盘的 SMART 数据（\(device)）。\(snippet)"
        return .failure(NSError(domain: "DiskWrites", code: 3, userInfo: [
            NSLocalizedDescriptionKey: message
        ]))
    }

    nonisolated static func match(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let hit = re.firstMatch(in: text, options: [], range: range),
              hit.numberOfRanges > 1,
              let captured = Range(hit.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    func seedPreview() {
        model = "APPLE SSD AP0512Z"
        device = "/dev/disk0"
        peak = 238.5
        totalGB = 20_137.5
        sessionGB = 1.12
        temperature = 30
        rate = 1.4
        errorText = nil
        topProcesses = [
            ProcWrite(id: "Google Chrome", name: "Google Chrome", bytes: 12_400_000_000),
            ProcWrite(id: "Finder", name: "Finder", bytes: 3_100_000_000),
            ProcWrite(id: "backupd", name: "backupd", bytes: 1_500_000_000),
            ProcWrite(id: "Xcode", name: "Xcode", bytes: 900_000_000),
            ProcWrite(id: "WeChat", name: "WeChat", bytes: 240_000_000),
            ProcWrite(id: "Photos", name: "Photos", bytes: 120_000_000),
            ProcWrite(id: "mds", name: "mds", bytes: 64_000_000),
            ProcWrite(id: "Spotlight", name: "Spotlight", bytes: 32_000_000),
            ProcWrite(id: "Terminal", name: "Terminal", bytes: 18_000_000),
            ProcWrite(id: "Mail", name: "Mail", bytes: 7_000_000)
        ]
        let now = Date()
        var points: [WriteSample] = []
        for i in stride(from: 59, through: 0, by: -1) {
            let x = Double(59 - i)
            var v = 0.4 + sin(x / 3.0) * 0.25
            if (8...10).contains(Int(x)) { v = 210 - Double(Int(x) - 8) * 12 }
            if (15...17).contains(Int(x)) { v = 195 - Double(Int(x) - 15) * 10 }
            if (22...24).contains(Int(x)) { v = 205 - Double(Int(x) - 22) * 9 }
            if (41...43).contains(Int(x)) { v = 168 - Double(Int(x) - 41) * 20 }
            if (46...48).contains(Int(x)) { v = 238 - Double(Int(x) - 46) * 6 }
            points.append(WriteSample(time: now.addingTimeInterval(-Double(i)), rate: max(0, v)))
        }
        history = points
    }
}

// MARK: - 界面

struct DashboardView: View {
    @EnvironmentObject var monitor: WriteMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)

            Text("当前写入速度")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)
                .padding(.bottom, 8)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(formatRate(monitor.rate))
                    .font(.system(size: 66, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color(red: 0.60, green: 0.85, blue: 0.96)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                Text("MB / 秒")
                    .font(.system(size: 16))
                    .foregroundColor(Palette.muted)
            }
            .padding(.bottom, 6)

            if let error = monitor.errorText {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.bad)
                    .lineLimit(2)
                    .padding(.vertical, 6)
            }

            ChartView(samples: monitor.history)
                .frame(height: 190)
                .padding(.top, 4)
                .padding(.bottom, 2)

            HStack {
                Text("60 秒前").font(.system(size: 11)).foregroundColor(Palette.muted)
                Spacer()
                Text("现在").font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            .padding(.bottom, 18)

            HStack(spacing: 10) {
                statTile("本次会话写入", monitor.sessionGB >= 1000
                         ? String(format: "%.2f", monitor.sessionGB / 1000) : String(format: "%.2f", monitor.sessionGB),
                         monitor.sessionGB >= 1000 ? "TB" : "GB")
                statTile("累计写入", monitor.totalGB >= 1000
                         ? String(format: "%.2f", monitor.totalGB / 1000) : String(format: "%.1f", monitor.totalGB),
                         monitor.totalGB >= 1000 ? "TB" : "GB")
                statTile("本次峰值", formatRate(monitor.peak), "MB/s")
                statTile("硬盘温度", monitor.temperature.map(String.init) ?? "–", "°C")
            }
            .padding(.bottom, 14)

            processSection
                .padding(.bottom, 12)

            HStack {
                Text("数据来源：smartctl + proc_pid_rusage")
                Spacer()
                Text("更新于 \(timeString(monitor.updated))")
            }
            .font(.system(size: 11))
            .foregroundColor(Palette.muted)
        }
        .padding(22)
        .frame(width: 600, height: 772, alignment: .topLeading)
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本次会话 · 谁在写")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.text)
                Spacer()
                Text(monitor.topProcesses.isEmpty
                     ? "累计写入量"
                     : "累计写入量 · \(monitor.topProcesses.count) 个")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
            }

            if monitor.topProcesses.isEmpty {
                Text(monitor.errorText == nil ? "还没有采集到明显的进程写入" : "暂时读不到进程数据")
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                let maxBytes = monitor.topProcesses.first?.bytes ?? 1
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(monitor.topProcesses) { item in
                            processRow(item, maxBytes: maxBytes)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(height: 173)
            }
        }
    }

    private func processRow(_ item: ProcWrite, maxBytes: UInt64) -> some View {
        let fraction = maxBytes == 0 ? 0 : Double(item.bytes) / Double(maxBytes)
        return HStack(spacing: 10) {
            Text(item.name)
                .font(.system(size: 11.5))
                .foregroundColor(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 140, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(Palette.accent.opacity(0.78))
                        .frame(width: max(3, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 6)

            Text(formatBytes(item.bytes))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(Palette.muted)
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: 17)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1e9
        if gigabytes >= 1 {
            return String(format: "%.1f GB", gigabytes)
        }
        return String(format: "%.0f MB", Double(bytes) / 1e6)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(monitor.model)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                Text("\(monitor.device) · 1 秒采样")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.muted)
            }
            Spacer()
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(monitor.isPaused ? Palette.warn : (monitor.errorText == nil ? Palette.ok : Palette.bad))
                        .frame(width: 7, height: 7)
                    Text(monitor.isPaused ? "已暂停" : (monitor.errorText == nil ? "实时" : "读取失败"))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.muted)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.05)))

                Button(monitor.isPaused ? "继续" : "暂停") {
                    monitor.isPaused.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Palette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
    }

    private func statTile(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(Palette.muted)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(Palette.text)
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
    }

    private func formatRate(_ value: Double) -> String {
        value < 0.05 ? "0.0" : String(format: "%.1f", value)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

struct ChartView: View {
    let samples: [WriteSample]

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 44
            let right = size.width - 8
            let top: CGFloat = 10
            let bottom = size.height - 16
            let now = Date()
            let window: TimeInterval = 60
            let start = now.addingTimeInterval(-window)

            let visible = samples.filter { $0.time >= start.addingTimeInterval(-2) }
            var maxRate: Double = 1
            for s in visible { maxRate = max(maxRate, s.rate) }
            let maxY = niceMax(maxRate * 1.15)

            // 网格与刻度
            for i in 0...4 {
                let y = bottom - (bottom - top) * CGFloat(i) / 4
                var line = Path()
                line.move(to: CGPoint(x: left, y: y))
                line.addLine(to: CGPoint(x: right, y: y))
                context.stroke(line, with: .color(Color.white.opacity(0.07)), lineWidth: 1)

                let value = maxY * Double(i) / 4
                let label = value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
                context.draw(
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundColor(Palette.muted),
                    at: CGPoint(x: left - 8, y: y),
                    anchor: .trailing
                )
            }

            guard visible.count >= 2 else {
                context.draw(
                    Text("收集中…").font(.system(size: 11)).foregroundColor(Palette.muted),
                    at: CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
                )
                return
            }

            func xPos(_ time: Date) -> CGFloat {
                let ratio = time.timeIntervalSince(start) / window
                return left + CGFloat(max(0, min(1, ratio))) * (right - left)
            }
            func yPos(_ value: Double) -> CGFloat {
                let ratio = min(value, maxY) / maxY
                return bottom - CGFloat(ratio) * (bottom - top)
            }

            var area = Path()
            area.move(to: CGPoint(x: xPos(visible[0].time), y: bottom))
            for s in visible {
                area.addLine(to: CGPoint(x: xPos(s.time), y: yPos(s.rate)))
            }
            area.addLine(to: CGPoint(x: xPos(visible[visible.count - 1].time), y: bottom))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [Palette.accent.opacity(0.30), Palette.accent.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: top),
                    endPoint: CGPoint(x: 0, y: bottom)
                )
            )

            var line = Path()
            for (index, s) in visible.enumerated() {
                let point = CGPoint(x: xPos(s.time), y: yPos(s.rate))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if let last = visible.last {
                let point = CGPoint(x: xPos(last.time), y: yPos(last.rate))
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)),
                    with: .color(Palette.accent.opacity(0.16))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                    with: .color(Palette.accent)
                )
            }
        }
    }

    private func niceMax(_ value: Double) -> Double {
        if value <= 0.6 { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10.0, exponent)
        for multiplier in [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] where value <= multiplier * base {
            return multiplier * base
        }
        return 10 * base
    }
}

// MARK: - 应用入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments

        if args.contains("--selftest") {
            let result = WriteMonitor.readSmart()
            switch result {
            case .success(let r):
                let tool = WriteMonitor.smartctlURL()?.path ?? "none"
                print("selftest ok: model=\(r.model) units=\(r.units) temp=\(r.temp.map(String.init) ?? "-")")
                print("smartctl=\(tool)")
            case .failure(let e):
                print("selftest failed: \(e.localizedDescription)")
            }

            let first = WriteMonitor.snapshotProcesses()
            Thread.sleep(forTimeInterval: 1.2)
            let second = WriteMonitor.snapshotProcesses()
            var deltas: [(String, UInt64)] = []
            for (pid, bytes) in second {
                if let prev = first[pid], bytes > prev {
                    deltas.append((WriteMonitor.processName(pid), bytes - prev))
                }
            }
            deltas.sort { $0.1 > $1.1 }
            print("proc: \(second.count) pids sampled, \(deltas.count) active")
            for (name, bytes) in deltas.prefix(5) {
                print(String(format: "  %-24@ %8.2f MB", name as NSString, Double(bytes) / 1e6))
            }
            exit(0)
        }

        if let index = args.firstIndex(of: "--render"), index + 1 < args.count {
            renderPreview(to: args[index + 1])
            exit(0)
        }

        if let index = args.firstIndex(of: "--proctest") {
            let seconds = index + 1 < args.count ? (Double(args[index + 1]) ?? 6) : 6
            let monitor = WriteMonitor()
            monitor.start()
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            print("proctest top:")
            for item in monitor.topProcesses {
                print(String(format: "  %-24@ %8.2f MB", item.name as NSString, Double(item.bytes) / 1e6))
            }
            print(String(format: "disk rate: %.2f MB/s, total %.1f GB, err: %@",
                         monitor.rate, monitor.totalGB, (monitor.errorText ?? "none") as NSString))
            exit(0)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    private func renderPreview(to path: String) {
        let monitor = WriteMonitor()
        monitor.seedPreview()
        let view = DashboardView()
            .environmentObject(monitor)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            print("render failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("png encode failed")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("rendered \(path)")
        } catch {
            print("write failed: \(error)")
        }
    }
}

@main
struct DiskWritesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var monitor = WriteMonitor()

    var body: some Scene {
        WindowGroup("磁盘写入量") {
            DashboardView()
                .environmentObject(monitor)
                .onAppear { monitor.start() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
