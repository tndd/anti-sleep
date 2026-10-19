import AppKit
import AntiSleepCore

// 画面倍率が1xのCIでも、実機と同じRetina用コントロールを描画する。
final class RetinaLayoutWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}

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
            let window = RetinaLayoutWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
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
            let startupLabel = views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "起動時にON" }!
            if detail.font?.pointSize != 13 || startupLabel.font?.pointSize != 13 {
                failures.append("\(name): 説明文・起動時ラベルは13ptが必要")
            }
            let rowFrame = panel.convert(row.bounds, from: row)
            let detailFrame = panel.convert(detail.bounds, from: detail)
            let gap = detailFrame.minY - rowFrame.maxY
            let bottom = rowFrame.minY
            let metrics: [String: Any] = ["state": name, "width": panel.bounds.width,
                "height": panel.bounds.height, "gapAbove": gap, "gapBelow": bottom,
                "rowHeight": rowFrame.height, "windowBackingScale": window.backingScaleFactor]
            results.append(metrics)
            // CIの1x画面でも実機と同じ2x描画→1x正規化で画素を比較する。
            if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(panel.bounds.width * 2), pixelsHigh: Int(panel.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                bitmap.size = panel.bounds.size
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                // 1x画面の文字用スムージングも無効化し、Retinaの描画条件に揃える。
                context.cgContext.setAllowsFontSmoothing(false)
                context.cgContext.setShouldSmoothFonts(false)
                context.cgContext.setAllowsFontSubpixelQuantization(false)
                context.cgContext.setShouldSubpixelQuantizeFonts(false)
                panel.displayIgnoringOpacity(panel.bounds, in: context)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            }
            if abs(bottom - 22) > 0.5 { failures.append("\(name): 行の下余白\(bottom)pt（期待22pt）") }
            if gap < 11.5 { failures.append("\(name): 上余白\(gap)pt（最小12pt）") }
            if name == "off" || name == "on" {
                if panel.bounds.size != NSSize(width: 300, height: 326) { failures.append("\(name): 通常サイズの不一致") }
                if gap > 14 { failures.append("\(name): 上余白\(gap)pt（期待12pt前後）") }
            }
            if !panel.helperButton.isHidden {
                let helperFrame = panel.convert(panel.helperButton.alignmentRect(forFrame: panel.helperButton.frame),
                                                from: panel.helperButton.superview)
                if helperFrame.minY < rowFrame.maxY + 11.5 { failures.append("\(name): ヘルパー操作と起動時設定の重複") }
            }
        }
        let report: [String: Any] = ["result": failures.isEmpty ? "PASS" : "FAIL", "states": results, "failures": failures]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("layout.json"))
        print(String(data: data, encoding: .utf8)!)
        exit(failures.isEmpty ? 0 : 1)
    }
}
