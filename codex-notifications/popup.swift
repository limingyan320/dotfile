#!/usr/bin/env swift

import AppKit
import Foundation

final class NotificationWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickableView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

func loadIcon(from path: String?) -> NSImage? {
    guard let path, !path.isEmpty else { return nil }
    return NSImage(contentsOfFile: path)
}

func makeLabel(text: String, font: NSFont, color: NSColor, lines: Int) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.maximumNumberOfLines = lines
    label.lineBreakMode = .byWordWrapping
    label.cell?.wraps = true
    label.cell?.isScrollable = false
    label.usesSingleLineMode = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

func splitBody(_ body: String) -> (String, String?) {
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var metaStart: Int?
    for (idx, line) in lines.enumerated() {
        if line.hasPrefix("机器: ") || line.hasPrefix("路径: ") {
            metaStart = idx
            break
        }
    }
    guard let metaStart else {
        return (body, nil)
    }
    let mainText = lines[..<metaStart].joined(separator: "\n")
    let metaText = lines[metaStart...].joined(separator: "\n")
    return (mainText, metaText.isEmpty ? nil : metaText)
}

func buildWindow(title: String, body: String, icon: NSImage?) -> NotificationWindow {
    let width: CGFloat = 428
    let minHeight: CGFloat = 132
    let maxHeight: CGFloat = 280
    let iconSize: CGFloat = 56
    let padding: CGFloat = 16
    let textWidth = width - padding * 3 - iconSize
    let (mainBody, metaBody) = splitBody(body)

    let titleLabel = makeLabel(
        text: title,
        font: .systemFont(ofSize: 16, weight: .bold),
        color: .white,
        lines: 4
    )
    titleLabel.preferredMaxLayoutWidth = textWidth

    let bodyLabel = makeLabel(
        text: mainBody,
        font: .systemFont(ofSize: 13, weight: .medium),
        color: NSColor(calibratedWhite: 0.95, alpha: 1.0),
        lines: 6
    )
    bodyLabel.preferredMaxLayoutWidth = textWidth

    let metaLabel = makeLabel(
        text: metaBody ?? "",
        font: .systemFont(ofSize: 11, weight: .regular),
        color: NSColor(calibratedWhite: 0.72, alpha: 1.0),
        lines: 3
    )
    metaLabel.preferredMaxLayoutWidth = textWidth
    metaLabel.isHidden = (metaBody == nil)

    let stack = NSStackView(views: [titleLabel, bodyLabel, metaLabel])
    stack.orientation = .vertical
    stack.spacing = 7
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false

    let iconView = NSImageView()
    iconView.image = icon
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.wantsLayer = true
    iconView.layer?.cornerRadius = 14
    iconView.layer?.masksToBounds = true
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        iconView.widthAnchor.constraint(equalToConstant: iconSize),
        iconView.heightAnchor.constraint(equalToConstant: iconSize),
    ])

    let content = ClickableView()
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 0.96).cgColor
    content.layer?.cornerRadius = 20
    content.layer?.borderWidth = 1
    content.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor

    let horizontal = NSStackView(views: [iconView, stack])
    horizontal.orientation = .horizontal
    horizontal.spacing = padding
    horizontal.alignment = .top
    horizontal.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(horizontal)

    NSLayoutConstraint.activate([
        horizontal.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
        horizontal.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
        horizontal.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
        horizontal.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding),
        stack.widthAnchor.constraint(equalToConstant: textWidth),
    ])

    content.layoutSubtreeIfNeeded()
    let textHeight = max(titleLabel.fittingSize.height + bodyLabel.fittingSize.height + stack.spacing, iconSize)
    let height = min(maxHeight, max(minHeight, textHeight + padding * 2))

    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NotificationWindow(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    window.contentView = content
    return window
}

func position(window: NSWindow) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
        return
    }
    let visible = screen.visibleFrame
    let marginX: CGFloat = 18
    let marginY: CGFloat = 16
    let x = visible.maxX - window.frame.width - marginX
    let y = visible.maxY - window.frame.height - marginY
    window.setFrameOrigin(NSPoint(x: x, y: y))
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    exit(0)
}

let title = args[1]
let body = args[2]
let icon = loadIcon(from: args.count >= 4 ? args[3] : nil)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = buildWindow(title: title, body: body, icon: icon)
position(window: window)
if let content = window.contentView as? ClickableView {
    content.onClick = {
        app.terminate(nil)
    }
}

window.alphaValue = 0
window.orderFrontRegardless()

NSAnimationContext.runAnimationGroup { context in
    context.duration = 0.18
    window.animator().alphaValue = 1
}

app.run()
