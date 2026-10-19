import AppKit
import AntiSleepCore

/// 実際のAppKitビューを配置し、承認モックの余白とエラー表示の非重複を確認する。
@main
struct PanelLayoutChecks {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let modes: [(String, ProtectionSwitchState, Bool)] = [
            ("off", ProtectionSwitchState(enabled: false, protection: nil), false),
            ("on", ProtectionSwitchState(enabled: true, protection: ProtectionStatus(
                idleProtected: true, lidProtected: true, detail: "ON")), false),
            ("unconfirmed", ProtectionSwitchState(enabled: true, protection: ProtectionStatus(
                idleProtected: true, lidProtected: false,
                detail: "ヘルパーを設定してから、もう一度スリープ防止をONにしてください。")), false),
            ("restore-failed", ProtectionSwitchState(enabled: true, protection: nil, restoreFailed: true), false),
            ("preview", ProtectionSwitchState(enabled: false, protection: nil), true)
        ]
        var failures: [String] = []
        var results: [[String: Any]] = []
        for (name, state, preview) in modes {
            let panel = PowerPanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 330))
            let window = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = panel
            panel.show(state, preview: preview)
            panel.showStartupOn(true)
            window.setContentSize(panel.contentSize)
            panel.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { [$0] + descendants($0) }
            }
            let views = descendants(panel)
            let detail = views.compactMap { $0 as? NSTextField }.first {
                $0.stringValue.contains("電源ボタンで") || $0.stringValue.contains("ふたを閉じても") ||
                $0.stringValue.contains("ヘルパーを設定して") || $0.stringValue.contains("設定を元に戻せなかった")
            }!
            let row = panel.startupSwitch.superview!
            let rowFrame = panel.convert(row.bounds, from: row)
            let detailFrame = panel.convert(detail.bounds, from: detail)
            let gap = detailFrame.minY - rowFrame.maxY
            let bottom = rowFrame.minY
            let metrics: [String: Any] = ["state": name, "width": panel.bounds.width,
                "height": panel.bounds.height, "gapAbove": gap, "gapBelow": bottom,
                "rowHeight": rowFrame.height]
            results.append(metrics)
            if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                panel.cacheDisplay(in: panel.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            }
            if abs(bottom - 20) > 0.5 { failures.append("\(name): 下余白\(bottom)pt（期待20pt）") }
            if gap < 19.5 { failures.append("\(name): 上余白\(gap)pt（最小20pt）") }
            if name == "off" || name == "on" {
                if panel.bounds.size != NSSize(width: 300, height: 330) { failures.append("\(name): 通常サイズの不一致") }
                if gap > 22 { failures.append("\(name): 上余白\(gap)pt（期待20pt前後）") }
            }
            if !panel.helperButton.isHidden {
                let helperFrame = panel.convert(panel.helperButton.alignmentRect(forFrame: panel.helperButton.frame),
                                                from: panel.helperButton.superview)
                if helperFrame.minY < rowFrame.maxY + 19.5 { failures.append("\(name): ヘルパー操作と起動時設定の重複") }
            }
        }
        let report: [String: Any] = ["result": failures.isEmpty ? "PASS" : "FAIL", "states": results, "failures": failures]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("layout.json"))
        print(String(data: data, encoding: .utf8)!)
        exit(failures.isEmpty ? 0 : 1)
    }
}
