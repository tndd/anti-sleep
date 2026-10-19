import AppKit
import AntiSleepCore

enum StatusDotIcon {
    static func make(on: Bool, size: CGFloat = 18) -> NSImage {
        let color: NSColor = on ? .systemGreen : .systemGray
        // 小さな表示でも輪郭を保ち、採用アイコンと同じ内側の光を添える。
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let diameter = size * 0.55
            let circle = NSBezierPath(ovalIn: NSRect(
                x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                width: diameter, height: diameter))
            NSGraphicsContext.saveGraphicsState()
            if on {
                let glow = NSShadow()
                glow.shadowColor = color.withAlphaComponent(0.25)
                glow.shadowBlurRadius = 2
                glow.shadowOffset = .zero
                glow.set()
            }
            color.setFill()
            circle.fill()
            NSGraphicsContext.restoreGraphicsState()
            let light = color.blended(withFraction: on ? 0.35 : 0.12, of: .white) ?? color
            NSGradient(starting: light, ending: color)?.draw(
                in: circle, relativeCenterPosition: NSPoint(x: -0.1, y: 0.25))
            (color.blended(withFraction: 0.25, of: .black) ?? color).setStroke()
            circle.lineWidth = 0.6
            circle.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = on ? "スリープ防止ON" : "スリープ防止OFF"
        return image
    }
}

final class PowerCircleButton: NSButton {
    var confirmedOn = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("未対応") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 7, dy: 7)
        let color: NSColor = confirmedOn ? .systemGreen : .systemGray
        color.withAlphaComponent(isHighlighted ? 0.75 : 1).setFill()
        NSBezierPath(ovalIn: circle).fill()
        if let symbol = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) {
            symbol.draw(in: NSRect(x: bounds.midX - 25, y: bounds.midY - 27, width: 50, height: 54))
        }
    }

    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds.insetBy(dx: 7, dy: 7)).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

final class PowerPanelView: NSView {
    let powerButton = PowerCircleButton(frame: .zero)
    let startupSwitch = NSSwitch()
    let helperButton = NSButton(title: "ヘルパーを設定…", target: nil, action: nil)
    let quitButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "終了")!, target: nil, action: nil)
    private let stack = NSStackView()
    private let startupRow = NSStackView()
    private let glyph = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "OFF")
    private let detail = NSTextField(wrappingLabelWithString: "電源ボタンでスリープ防止をONにできます。")
    private let previewNote = NSTextField(labelWithString: "")
    private var working = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(startupRow)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: startupRow.topAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22)
        ])
        let header = NSStackView()
        header.spacing = 6
        glyph.image = StatusDotIcon.make(on: false)
        glyph.widthAnchor.constraint(equalToConstant: 17).isActive = true
        glyph.heightAnchor.constraint(equalToConstant: 17).isActive = true
        let title = NSTextField(labelWithString: "AntiSleep")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        header.addArrangedSubview(glyph)
        header.addArrangedSubview(title)
        stack.addArrangedSubview(header)
        powerButton.widthAnchor.constraint(equalToConstant: 132).isActive = true
        powerButton.heightAnchor.constraint(equalToConstant: 132).isActive = true
        stack.addArrangedSubview(powerButton)
        stateLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        stack.addArrangedSubview(stateLabel)
        detail.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 256
        stack.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        previewNote.font = .systemFont(ofSize: 10)
        previewNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(previewNote)
        helperButton.controlSize = .small
        helperButton.font = .systemFont(ofSize: 11)
        helperButton.isHidden = true
        stack.addArrangedSubview(helperButton)
        startupRow.orientation = .horizontal
        startupRow.alignment = .centerY
        startupRow.spacing = 8
        let startupLabel = NSTextField(labelWithString: "起動時にON")
        startupLabel.font = .systemFont(ofSize: 12)
        startupLabel.textColor = .secondaryLabelColor
        startupSwitch.controlSize = .mini
        startupSwitch.setAccessibilityLabel("起動時にON")
        startupSwitch.setAccessibilityHelp("次回のアプリ起動時から適用します。現在のスリープ防止状態は変更しません。")
        startupRow.addArrangedSubview(startupLabel)
        startupRow.addArrangedSubview(startupSwitch)
        startupRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            startupRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            startupRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            startupRow.heightAnchor.constraint(equalToConstant: 28)
        ])
        quitButton.isBordered = false
        quitButton.contentTintColor = .secondaryLabelColor
        quitButton.toolTip = "設定を元に戻してAntiSleepを終了"
        quitButton.setAccessibilityLabel("設定を元に戻して終了")
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quitButton)
        NSLayoutConstraint.activate([
            quitButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            quitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            quitButton.widthAnchor.constraint(equalToConstant: 28),
            quitButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("未対応") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    var contentSize: NSSize { NSSize(width: 300, height: max(330, fittingSize.height)) }

    func showStartupOn(_ value: Bool) {
        startupSwitch.state = value ? .on : .off
        startupSwitch.toolTip = "次回は\(value ? "ON" : "OFF")で起動します。現在の状態は変更しません。"
    }

    func show(_ state: ProtectionSwitchState, preview: Bool = false) {
        powerButton.confirmedOn = state.confirmedOn
        glyph.image = StatusDotIcon.make(on: state.confirmedOn)
        stateLabel.stringValue = working ? "切り替え中…" : (state.confirmedOn ? "ON" : (state.enabled ? "確認が必要です" : "OFF"))
        stateLabel.font = .systemFont(ofSize: state.enabled && !state.confirmedOn ? 18 : 25, weight: .semibold)
        stateLabel.textColor = state.confirmedOn ? .systemGreen : .secondaryLabelColor
        if state.restoreFailed {
            detail.stringValue = "設定を元に戻せなかったため、ONを維持しています。もう一度お試しください。"
        } else if !state.enabled {
            detail.stringValue = "電源ボタンでスリープ防止を\nONにできます。"
        } else if state.confirmedOn {
            detail.stringValue = "ふたを閉じても処理を継続。\n画面は消灯できます。"
        } else {
            detail.stringValue = state.protection?.detail ?? "保護を確認しています。"
        }
        helperButton.isHidden = !state.enabled || state.confirmedOn
        previewNote.stringValue = "プレビュー・電源設定は変更しません"
        previewNote.isHidden = !preview
        powerButton.setAccessibilityLabel(state.enabled ? "スリープ防止をOFFにする" : "スリープ防止をONにする")
    }

    func setWorking(_ value: Bool) {
        working = value
        powerButton.isEnabled = !value
        helperButton.isEnabled = !value
        quitButton.isEnabled = !value
        if value { stateLabel.stringValue = "切り替え中…" }
    }
}
