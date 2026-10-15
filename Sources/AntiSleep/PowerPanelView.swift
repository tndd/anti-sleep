import AppKit
import AntiSleepCore

enum BoltIcon {
    static func make(on: Bool, size: CGFloat = 18) -> NSImage? {
        let color: NSColor = on ? .systemGreen : .systemGray
        guard let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: on ? "スリープ防止ON" : "スリープ防止OFF"),
              let colored = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) else { return nil }
        // テンプレート画像にせず、メニューバーでも緑・灰色を維持する。
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            colored.draw(in: rect)
            return true
        }
        image.isTemplate = false
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
    let screenButton = NSButton(title: "画面を消灯", target: nil, action: nil)
    let helperButton = NSButton(title: "ヘルパーを設定…", target: nil, action: nil)
    let quitButton = NSButton(title: "終了", target: nil, action: nil)
    private let glyph = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "OFF")
    private let detail = NSTextField(wrappingLabelWithString: "電源ボタンでスリープ防止をONにできます。")
    private let previewNote = NSTextField(labelWithString: "")
    private var working = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22)
        ])
        let header = NSStackView()
        header.spacing = 6
        glyph.image = BoltIcon.make(on: false)
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
        detail.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        previewNote.font = .systemFont(ofSize: 10)
        previewNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(previewNote)
        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let footer = NSStackView()
        footer.spacing = 8
        for button in [screenButton, quitButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            footer.addArrangedSubview(button)
        }
        stack.addArrangedSubview(footer)
        helperButton.controlSize = .small
        helperButton.font = .systemFont(ofSize: 11)
        helperButton.isHidden = true
        stack.addArrangedSubview(helperButton)
    }

    required init?(coder: NSCoder) { fatalError("未対応") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    func show(_ state: ProtectionSwitchState, preview: Bool = false) {
        powerButton.confirmedOn = state.confirmedOn
        glyph.image = BoltIcon.make(on: state.confirmedOn)
        stateLabel.stringValue = working ? "切り替え中…" : (state.confirmedOn ? "ON" : (state.enabled ? "確認が必要です" : "OFF"))
        stateLabel.font = .systemFont(ofSize: state.enabled && !state.confirmedOn ? 18 : 25, weight: .semibold)
        stateLabel.textColor = state.confirmedOn ? .systemGreen : .secondaryLabelColor
        if state.restoreFailed {
            detail.stringValue = "設定を元に戻せなかったため、ONを維持しています。もう一度お試しください。"
        } else if !state.enabled {
            detail.stringValue = "電源ボタンでスリープ防止をONにできます。"
        } else if state.confirmedOn {
            detail.stringValue = "ふたを閉じても処理を継続。\n画面は消灯できます。"
        } else {
            detail.stringValue = state.protection?.detail ?? "保護を確認しています。"
        }
        helperButton.isHidden = !state.enabled || state.confirmedOn
        previewNote.stringValue = preview ? "プレビュー・電源設定は変更しません" : "アプリを開くだけではONになりません"
        powerButton.setAccessibilityLabel(state.enabled ? "スリープ防止をOFFにする" : "スリープ防止をONにする")
    }

    func setWorking(_ value: Bool) {
        working = value
        powerButton.isEnabled = !value
        if value { stateLabel.stringValue = "切り替え中…" }
    }
}
