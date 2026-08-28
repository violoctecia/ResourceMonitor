import Cocoa
import ServiceManagement

let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

let ramWarnMB = 500
let ramNoteMB = 150
let cpuWarnPct = 50.0
let cpuNotePct = 15.0

enum Severity {
    case green, yellow, red
    var color: NSColor {
        switch self {
        case .green: return .systemGreen
        case .yellow: return NSColor(calibratedRed: 0.85, green: 0.65, blue: 0.0, alpha: 1.0)
        case .red: return .systemRed
        }
    }
}

func severityFor(mb: Int, cpu: Double) -> Severity {
    if mb >= ramWarnMB || cpu >= cpuWarnPct { return .red }
    if mb >= ramNoteMB || cpu >= cpuNotePct { return .yellow }
    return .green
}

func fmtPct(_ v: Double) -> String {
    String(format: "%.0f%%", v)
}

enum Lang: String { case ru, en }

var currentLang: Lang = {
    if let saved = UserDefaults.standard.string(forKey: "AppLanguage"), let l = Lang(rawValue: saved) {
        return l
    }
    let sys = Locale.preferredLanguages.first ?? "en"
    return sys.hasPrefix("ru") ? .ru : .en
}()

func setLang(_ l: Lang) {
    currentLang = l
    UserDefaults.standard.set(l.rawValue, forKey: "AppLanguage")
}

enum T {
    static var listeningPorts: String { currentLang == .ru ? "Прослушиваемые порты" : "Listening ports" }
    static var none: String { currentLang == .ru ? "нет" : "none" }
    static var dockerContainers: String { currentLang == .ru ? "Docker контейнеры" : "Docker containers" }
    static var noneRunning: String { currentLang == .ru ? "ничего не запущено" : "none running" }
    static var dockerNotFound: String { currentLang == .ru ? "docker не найден" : "docker not found" }
    static var kill: String { currentLang == .ru ? "Завершить" : "Kill" }
    static var stop: String { currentLang == .ru ? "Остановить" : "Stop" }
    static var portsLabel: String { currentLang == .ru ? "порты" : "ports" }
    static var refresh: String { currentLang == .ru ? "Обновить" : "Refresh" }
    static var quit: String { currentLang == .ru ? "Выйти" : "Quit" }
    static var launchAtLogin: String { currentLang == .ru ? "Запускать при входе" : "Launch at Login" }
    static var language: String { currentLang == .ru ? "Язык" : "Language" }
    static var ramUsed: String { currentLang == .ru ? "RAM занято" : "RAM used" }
    static var apps: String { currentLang == .ru ? "Приложения" : "Applications" }
    static var quitApp: String { currentLang == .ru ? "Закрыть" : "Quit" }
}

func isLoginItemEnabled() -> Bool {
    if #available(macOS 13.0, *) {
        return SMAppService.mainApp.status == .enabled
    }
    return false
}

func setLoginItemEnabled(_ enabled: Bool) {
    guard #available(macOS 13.0, *) else { return }
    do {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    } catch {
        NSLog("Login item toggle failed: \(error)")
    }
}

func shell(_ path: String, _ args: [String]) -> String {
    guard FileManager.default.fileExists(atPath: path) else { return "" }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = Pipe()
    do { try task.run() } catch { return "" }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func findDocker() -> String? {
    for p in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"] {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
}

func regexMatch(_ pattern: String, in text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range) else { return nil }
    var groups: [String] = []
    for i in 0..<m.numberOfRanges {
        if let r = Range(m.range(at: i), in: text) {
            groups.append(String(text[r]))
        } else {
            groups.append("")
        }
    }
    return groups
}

struct ProcInfo { let etime: String; let rss: Int; let cpu: Double; let name: String; let appName: String; let isApp: Bool }
struct PortRow { let pid: String; let port: String; let comm: String; let mb: Int; let cpuPct: Double; let secs: Int; let dur: String; let cwd: String? }
struct ContainerRow { let name: String; let status: String; let ports: String; let secs: Int; let cpuPct: Double; let memMB: Int }
struct AppRow { let name: String; let mb: Int; let cpuPct: Double; let isApp: Bool }

func appNameFor(_ path: String) -> (name: String, isApp: Bool) {
    if let g = regexMatch(#"/([^/]+)\.app/"#, in: path) {
        return (g[1], true)
    }
    return ((path as NSString).lastPathComponent, false)
}

func etimeToSecs(_ etimeIn: String) -> Int {
    var e = etimeIn
    var days = 0
    if let dash = e.firstIndex(of: "-") {
        days = Int(e[e.startIndex..<dash]) ?? 0
        e = String(e[e.index(after: dash)...])
    }
    let parts = e.split(separator: ":").compactMap { Int($0) }
    var h = 0, m = 0, s = 0
    if parts.count == 3 { h = parts[0]; m = parts[1]; s = parts[2] }
    else if parts.count == 2 { m = parts[0]; s = parts[1] }
    else if parts.count == 1 { s = parts[0] }
    return days * 86400 + h * 3600 + m * 60 + s
}

func humanDur(_ secs: Int) -> String {
    let d = secs / 86400
    let h = (secs % 86400) / 3600
    let m = (secs % 3600) / 60
    if d > 0 { return "\(d)d\(h)h" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(m)m"
}

func parsePercent(_ s: String) -> Double {
    Double(s.replacingOccurrences(of: "%", with: "")) ?? 0
}

func parseSizeToMB(_ token: String) -> Int {
    guard let g = regexMatch(#"([\d.]+)\s*(GiB|MiB|KiB|GB|MB|KB|B)"#, in: token) else { return 0 }
    let value = Double(g[1]) ?? 0
    switch g[2] {
    case "GiB", "GB": return Int(value * 1024)
    case "MiB", "MB": return Int(value)
    case "KiB", "KB": return Int(value / 1024)
    default: return 0
    }
}

func totalMemGB() -> Double {
    let out = shell("/usr/sbin/sysctl", ["-n", "hw.memsize"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let bytes = Double(out) ?? 0
    return bytes / 1024 / 1024 / 1024
}

func parseSizeToGB(_ token: String) -> Double {
    guard let g = regexMatch(#"([\d.]+)([A-Za-z]+)"#, in: token) else { return 0 }
    let v = Double(g[1]) ?? 0
    switch g[2] {
    case "G": return v
    case "M": return v / 1024
    case "K": return v / 1024 / 1024
    default: return v
    }
}

func makeStatusBarImage(cpuPct: Int, memPct: Int) -> NSImage {
    let width: CGFloat = 60, height: CGFloat = 18, barH: CGFloat = 5, trackW = width - 4
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    func drawBar(y: CGFloat, pct: Int) {
        let track = NSBezierPath(roundedRect: NSRect(x: 2, y: y, width: trackW, height: barH), xRadius: barH / 2, yRadius: barH / 2)
        NSColor.black.withAlphaComponent(0.25).setFill()
        track.fill()
        let fillW = trackW * CGFloat(min(max(pct, 0), 100)) / 100
        if fillW >= 1 {
            let fg = NSBezierPath(roundedRect: NSRect(x: 2, y: y, width: fillW, height: barH), xRadius: barH / 2, yRadius: barH / 2)
            NSColor.black.setFill()
            fg.fill()
        }
    }
    drawBar(y: height - barH - 3, pct: cpuPct)
    drawBar(y: 3, pct: memPct)
    image.unlockFocus()
    image.isTemplate = true
    return image
}

func cpuMemSummary() -> (cpuPct: Int, memStr: String, memPct: Int) {
    let out = shell("/usr/bin/top", ["-l", "1", "-n", "0", "-s", "0"])
    var cpuPct = 0
    var memStr = "?"
    var memPct = 0
    let totalGB = totalMemGB()
    for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
        let s = String(line)
        if s.hasPrefix("CPU usage") {
            if let g = regexMatch(#"([\d.]+)% idle"#, in: s), let idle = Double(g[1]) {
                cpuPct = Int((100 - idle).rounded())
            }
        }
        if s.hasPrefix("PhysMem") {
            if let g = regexMatch(#"PhysMem:\s*([0-9]+[A-Za-z]) used"#, in: s) {
                memStr = g[1]
                if totalGB > 0 {
                    memPct = Int((parseSizeToGB(g[1]) / totalGB * 100).rounded())
                }
            }
        }
    }
    return (cpuPct, memStr, memPct)
}

func allProcesses() -> [String: ProcInfo] {
    let out = shell("/bin/ps", ["-axo", "pid=,etime=,rss=,pcpu=,comm="])
    var dict: [String: ProcInfo] = [:]
    for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let g = regexMatch(#"^\s*(\d+)\s+([\d:-]+)\s+(\d+)\s+([\d.,]+)\s+(.+)$"#, in: String(line)) else { continue }
        let pid = g[1], etime = g[2], rss = Int(g[3]) ?? 0, cpu = Double(g[4].replacingOccurrences(of: ",", with: ".")) ?? 0, path = g[5]
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { continue }
        let (appName, isApp) = appNameFor(path)
        dict[pid] = ProcInfo(etime: etime, rss: rss, cpu: cpu, name: processName(path), appName: appName, isApp: isApp)
    }
    return dict
}

func processName(_ path: String) -> String {
    return (path as NSString).lastPathComponent
}

func cwdFor(_ pid: String) -> String? {
    let out = shell("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"])
    for line in out.split(separator: "\n") where line.hasPrefix("n") {
        let path = String(line.dropFirst())
        if path == "/" { return nil }
        return path
    }
    return nil
}

func listeningPorts(_ procs: [String: ProcInfo]) -> [PortRow] {
    let out = shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])
    var seen = Set<String>()
    var cwdCache: [String: String?] = [:]
    var rows: [PortRow] = []
    let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
    for line in lines.dropFirst() {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard cols.count >= 9 else { continue }
        let pid = cols[1], name = cols[8]
        let port = String(name.split(separator: ":").last ?? "")
        let key = "\(pid):\(port)"
        guard !seen.contains(key), let info = procs[pid] else { continue }
        seen.insert(key)
        if cwdCache[pid] == nil { cwdCache[pid] = .some(cwdFor(pid)) }
        let cwd = cwdCache[pid] ?? nil
        let secs = etimeToSecs(info.etime)
        rows.append(PortRow(pid: pid, port: port, comm: info.name, mb: info.rss / 1024, cpuPct: info.cpu, secs: secs, dur: humanDur(secs), cwd: cwd))
    }
    return rows.sorted { max($0.mb, Int($0.cpuPct * 10)) > max($1.mb, Int($1.cpuPct * 10)) }
}

func topApps(_ procs: [String: ProcInfo]) -> [AppRow] {
    var sums: [String: (mb: Int, cpu: Double, isApp: Bool)] = [:]
    for info in procs.values {
        if info.appName == "ResourceMonitor" { continue }
        var entry = sums[info.appName] ?? (0, 0, info.isApp)
        entry.mb += info.rss / 1024
        entry.cpu += info.cpu
        sums[info.appName] = entry
    }
    return sums.map { AppRow(name: $0.key, mb: $0.value.mb, cpuPct: $0.value.cpu, isApp: $0.value.isApp) }
        .sorted { max($0.mb, Int($0.cpuPct * 10)) > max($1.mb, Int($1.cpuPct * 10)) }
}

func dockerStats(_ docker: String) -> [String: (cpu: Double, mb: Int)] {
    let out = shell(docker, ["stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"])
    var dict: [String: (Double, Int)] = [:]
    for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 3 else { continue }
        let memToken = parts[2].components(separatedBy: " / ").first ?? "0MiB"
        dict[parts[0]] = (parsePercent(parts[1]), parseSizeToMB(memToken))
    }
    return dict
}

func dockerContainers() -> [ContainerRow]? {
    guard let docker = findDocker() else { return nil }
    let stats = dockerStats(docker)
    let out = shell(docker, ["ps", "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"])
    var rows: [ContainerRow] = []
    for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 2 else { continue }
        let name = parts[0], status = parts[1]
        let ports = parts.count > 2 ? parts[2] : ""
        var secs = 0
        if status.contains("Up About an hour") {
            secs = 3600
        } else if let g = regexMatch(#"Up (\d+) (second|minute|hour|day)s?"#, in: status) {
            let n = Int(g[1]) ?? 0
            let mult = ["second": 1, "minute": 60, "hour": 3600, "day": 86400][g[2]] ?? 1
            secs = n * mult
        }
        let stat = stats[name] ?? (0, 0)
        rows.append(ContainerRow(name: name, status: status, ports: ports, secs: secs, cpuPct: stat.cpu, memMB: stat.mb))
    }
    return rows.sorted { max($0.memMB, Int($0.cpuPct * 10)) > max($1.memMB, Int($1.cpuPct * 10)) }
}

final class BarMenuItemView: NSView {
    init(label: String, pct: Int, detail: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        autoresizingMask = [.width]

        let nameField = NSTextField(labelWithString: label)
        nameField.frame = NSRect(x: 14, y: 5, width: 38, height: 16)
        nameField.font = NSFont.menuFont(ofSize: 12)
        nameField.autoresizingMask = [.maxXMargin]
        addSubview(nameField)

        let detailField = NSTextField(labelWithString: detail)
        detailField.frame = NSRect(x: 194, y: 5, width: 80, height: 16)
        detailField.font = NSFont.menuFont(ofSize: 12)
        detailField.lineBreakMode = .byClipping
        detailField.alignment = .right
        detailField.autoresizingMask = [.minXMargin]
        addSubview(detailField)

        let bar = NSProgressIndicator(frame: NSRect(x: 56, y: 8, width: 128, height: 10))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = Double(pct)
        bar.autoresizingMask = [.width]
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class RowMenuItemView: NSView {
    init(left: String, right: String, color: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 20))
        autoresizingMask = [.width]

        let leftField = NSTextField(labelWithString: left)
        leftField.frame = NSRect(x: 14, y: 2, width: 220, height: 16)
        leftField.font = NSFont.menuFont(ofSize: 13)
        leftField.textColor = color
        leftField.lineBreakMode = .byTruncatingTail
        leftField.autoresizingMask = [.maxXMargin]
        addSubview(leftField)

        let rightField = NSTextField(labelWithString: right)
        rightField.frame = NSRect(x: 246, y: 2, width: 220, height: 16)
        rightField.font = NSFont.menuFont(ofSize: 13)
        rightField.textColor = color
        rightField.alignment = .right
        rightField.lineBreakMode = .byClipping
        rightField.autoresizingMask = [.minXMargin]
        addSubview(rightField)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    let docker = findDocker()
    let workQueue = DispatchQueue(label: "resourcemonitor.refresh", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func coloredItem(_ left: String, _ right: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: "\(left) \(right)", action: nil, keyEquivalent: "")
        item.view = RowMenuItemView(left: left, right: right, color: color)
        return item
    }

    @objc func killProcess(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? String else { return }
        workQueue.async { [weak self] in
            _ = shell("/bin/kill", ["-9", pid])
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc func stopContainer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let docker = docker else { return }
        workQueue.async { [weak self] in
            _ = shell(docker, ["stop", name])
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        workQueue.async { [weak self] in
            _ = shell("/usr/bin/osascript", ["-e", "tell application \"\(escaped)\" to quit"])
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc func refreshClicked(_ sender: Any?) {
        refresh()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        setLoginItemEnabled(!isLoginItemEnabled())
        refresh()
    }

    @objc func setLangRu(_ sender: Any?) {
        setLang(.ru)
        refresh()
    }

    @objc func setLangEn(_ sender: Any?) {
        setLang(.en)
        refresh()
    }

    struct RefreshData {
        let cpuPct: Int
        let memStr: String
        let memPct: Int
        let apps: [AppRow]
        let ports: [PortRow]
        let containers: [ContainerRow]?
    }

    var isRefreshing = false
    var hasLoadedOnce = false

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if !hasLoadedOnce {
            statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            statusItem.button?.title = ""
        }
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let (cpuPct, memStr, memPct) = cpuMemSummary()
            let procs = allProcesses()
            let apps = Array(topApps(procs).prefix(8))
            let ports = listeningPorts(procs)
            let containers = dockerContainers()
            let data = RefreshData(cpuPct: cpuPct, memStr: memStr, memPct: memPct, apps: apps, ports: ports, containers: containers)
            DispatchQueue.main.async {
                self.applyData(data)
                self.isRefreshing = false
                self.hasLoadedOnce = true
            }
        }
    }

    func applyData(_ d: RefreshData) {
        let cpuPct = d.cpuPct, memStr = d.memStr, memPct = d.memPct
        let apps = d.apps, ports = d.ports, containers = d.containers

        var anySevere = false
        for r in ports where severityFor(mb: r.mb, cpu: r.cpuPct) == .red { anySevere = true }
        if let containers = containers {
            for c in containers where severityFor(mb: c.memMB, cpu: c.cpuPct) == .red { anySevere = true }
        }
        let badge = anySevere ? " \u{26A0}\u{FE0F}" : ""

        statusItem.button?.image = makeStatusBarImage(cpuPct: cpuPct, memPct: memPct)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = badge
        statusItem.button?.toolTip = "CPU \(cpuPct)%  ·  RAM \(memStr) (\(memPct)%)"

        let menu = NSMenu()
        let cpuItem = NSMenuItem()
        cpuItem.view = BarMenuItemView(label: "CPU", pct: cpuPct, detail: "\(cpuPct)%")
        menu.addItem(cpuItem)
        let ramItem = NSMenuItem()
        ramItem.view = BarMenuItemView(label: "RAM", pct: memPct, detail: "\(memPct)% \(memStr)")
        menu.addItem(ramItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: T.apps, action: nil, keyEquivalent: "")
        if apps.isEmpty {
            menu.addItem(withTitle: "  \(T.none)", action: nil, keyEquivalent: "")
        }
        for a in apps {
            let item = coloredItem("  \(a.name)", "CPU \(fmtPct(a.cpuPct))  RAM \(a.mb)MB", color: severityFor(mb: a.mb, cpu: a.cpuPct).color)
            if a.isApp {
                let sub = NSMenu()
                let quit = NSMenuItem(title: "\(T.quitApp) \(a.name)", action: #selector(quitApp(_:)), keyEquivalent: "")
                quit.target = self
                quit.representedObject = a.name
                sub.addItem(quit)
                item.submenu = sub
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: T.listeningPorts, action: nil, keyEquivalent: "")
        if ports.isEmpty {
            menu.addItem(withTitle: "  \(T.none)", action: nil, keyEquivalent: "")
        }
        for r in ports {
            let projectSuffix = r.cwd.map { " — \(($0 as NSString).lastPathComponent)" } ?? ""
            let item = coloredItem("  :\(r.port)  \(r.comm)\(projectSuffix)", "CPU \(fmtPct(r.cpuPct))  RAM \(r.mb)MB  \(r.dur)", color: severityFor(mb: r.mb, cpu: r.cpuPct).color)
            let sub = NSMenu()
            if let cwd = r.cwd {
                sub.addItem(withTitle: cwd, action: nil, keyEquivalent: "")
                sub.addItem(.separator())
            }
            let kill = NSMenuItem(title: "\(T.kill) \(r.comm) (pid \(r.pid))", action: #selector(killProcess(_:)), keyEquivalent: "")
            kill.target = self
            kill.representedObject = r.pid
            sub.addItem(kill)
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: T.dockerContainers, action: nil, keyEquivalent: "")
        if let containers = containers {
            if containers.isEmpty {
                menu.addItem(withTitle: "  \(T.noneRunning)", action: nil, keyEquivalent: "")
            }
            for c in containers {
                let item = coloredItem("  \(c.name)", "CPU \(fmtPct(c.cpuPct))  RAM \(c.memMB)MB  \(c.status)", color: severityFor(mb: c.memMB, cpu: c.cpuPct).color)
                let sub = NSMenu()
                if !c.ports.isEmpty {
                    sub.addItem(withTitle: "\(T.portsLabel): \(c.ports)", action: nil, keyEquivalent: "")
                }
                let stop = NSMenuItem(title: "\(T.stop) \(c.name)", action: #selector(stopContainer(_:)), keyEquivalent: "")
                stop.target = self
                stop.representedObject = c.name
                sub.addItem(stop)
                item.submenu = sub
                menu.addItem(item)
            }
        } else {
            menu.addItem(withTitle: "  \(T.dockerNotFound)", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())

        let langMenu = NSMenu()
        let ruItem = NSMenuItem(title: "Русский", action: #selector(setLangRu(_:)), keyEquivalent: "")
        ruItem.target = self
        ruItem.state = currentLang == .ru ? .on : .off
        let enItem = NSMenuItem(title: "English", action: #selector(setLangEn(_:)), keyEquivalent: "")
        enItem.target = self
        enItem.state = currentLang == .en ? .on : .off
        langMenu.addItem(ruItem)
        langMenu.addItem(enItem)
        let langParent = NSMenuItem(title: T.language, action: nil, keyEquivalent: "")
        langParent.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        langParent.submenu = langMenu
        menu.addItem(langParent)

        let loginItem = NSMenuItem(title: T.launchAtLogin, action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        loginItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: T.refresh, action: #selector(refreshClicked(_:)), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: T.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
