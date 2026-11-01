import Foundation
import UIKit
import AppBundle

// The pictures of the welcome pages, 200×200, made of the same elements as the app: chat bubbles, a chat list card
// with topics and status dots, the tab bar. Each plays when its page comes to the screen.

struct AgentgramIntroPalette {
    let isDark: Bool
    let card: UIColor
    let text: UIColor
    let secondaryText: UIColor
    let separator: UIColor
    let incomingBubble: UIColor
    let tabBar: UIColor
    let accent = UIColor(rgb: 0x2AABEE)
    let working = UIColor(rgb: 0xF5B70A)

    init(background: UIColor) {
        var white: CGFloat = 1.0
        background.getWhite(&white, alpha: nil)
        self.isDark = white < 0.5
        self.card = self.isDark ? UIColor(rgb: 0x1C1C1E) : .white
        self.text = self.isDark ? .white : .black
        self.secondaryText = UIColor(rgb: 0x8E8E93)
        self.separator = self.isDark ? UIColor(rgb: 0x38383A) : UIColor(rgb: 0xE5E5EA)
        self.incomingBubble = self.isDark ? UIColor(rgb: 0x2C2C2E) : UIColor(rgb: 0xF1F1F4)
        self.tabBar = self.isDark ? UIColor(rgb: 0x161618) : UIColor(rgb: 0xF9F9F9)
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: 1.0)
    }
}

class AgentgramIntroArtwork: UIView {
    let palette: AgentgramIntroPalette

    init(palette: AgentgramIntroPalette) {
        self.palette = palette
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 200.0, height: 200.0))
        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func play() {
    }

    func stop() {
    }

    // the content is laid out for 200×200 and scaled to the view
    let content = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 200.0, height: 200.0))

    func setupContent() {
        self.addSubview(self.content)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = self.bounds.width / 200.0
        self.content.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.content.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
    }
}

private func iconImage(eyes: Bool) -> UIImage? {
    return UIImage(bundleImageName: eyes ? "AgentgramIntroIcon" : "AgentgramIntroIconNoEyes")
}

private func avatarView(size: CGFloat) -> UIImageView {
    let view = UIImageView(image: iconImage(eyes: true))
    view.frame = CGRect(x: 0.0, y: 0.0, width: size, height: size)
    view.layer.cornerRadius = size / 2.0
    view.clipsToBounds = true
    return view
}

private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = UIFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

private func cardView(palette: AgentgramIntroPalette, frame: CGRect) -> (UIView, UIView) {
    let shadow = UIView(frame: frame)
    shadow.layer.shadowColor = UIColor(rgb: 0x113C6E).cgColor
    shadow.layer.shadowOpacity = palette.isDark ? 0.0 : 0.16
    shadow.layer.shadowRadius = 11.0
    shadow.layer.shadowOffset = CGSize(width: 0.0, height: 6.0)
    shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: 18.0).cgPath
    let card = UIView(frame: shadow.bounds)
    card.backgroundColor = palette.card
    card.layer.cornerRadius = 18.0
    card.clipsToBounds = true
    shadow.addSubview(card)
    return (shadow, card)
}

private func bubblePath(size: CGSize, outgoing: Bool) -> UIBezierPath {
    let big: CGFloat = 16.0
    let small: CGFloat = 4.0
    let r = CGRect(origin: CGPoint(), size: size)
    let bl = outgoing ? big : small
    let br = outgoing ? small : big
    let path = UIBezierPath()
    path.move(to: CGPoint(x: big, y: 0.0))
    path.addLine(to: CGPoint(x: r.maxX - big, y: 0.0))
    path.addArc(withCenter: CGPoint(x: r.maxX - big, y: big), radius: big, startAngle: -.pi / 2.0, endAngle: 0.0, clockwise: true)
    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
    path.addArc(withCenter: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: 0.0, endAngle: .pi / 2.0, clockwise: true)
    path.addLine(to: CGPoint(x: bl, y: r.maxY))
    path.addArc(withCenter: CGPoint(x: bl, y: r.maxY - bl), radius: bl, startAngle: .pi / 2.0, endAngle: .pi, clockwise: true)
    path.addLine(to: CGPoint(x: 0.0, y: big))
    path.addArc(withCenter: CGPoint(x: big, y: big), radius: big, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
    path.close()
    return path
}

private final class BubbleView: UIView {
    init(text: String, time: String, outgoing: Bool, palette: AgentgramIntroPalette, maxWidth: CGFloat) {
        super.init(frame: CGRect())
        let textColor: UIColor = outgoing ? .white : palette.text
        let timeColor: UIColor = outgoing ? UIColor.white.withAlphaComponent(0.75) : palette.secondaryText
        let string = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 12.0), .foregroundColor: textColor])
        string.append(NSAttributedString(string: "  " + time, attributes: [.font: UIFont.systemFont(ofSize: 10.0), .foregroundColor: timeColor]))
        let textLabel = UILabel()
        textLabel.attributedText = string
        textLabel.numberOfLines = 0
        let textSize = textLabel.sizeThatFits(CGSize(width: maxWidth - 22.0, height: 100.0))
        textLabel.frame = CGRect(x: 11.0, y: 7.0, width: ceil(textSize.width), height: ceil(textSize.height))
        let size = CGSize(width: ceil(textSize.width) + 22.0, height: ceil(textSize.height) + 14.0)
        self.frame = CGRect(origin: CGPoint(), size: size)
        let shape = CAShapeLayer()
        shape.path = bubblePath(size: size, outgoing: outgoing).cgPath
        shape.fillColor = (outgoing ? palette.accent : palette.incomingBubble).cgColor
        self.layer.addSublayer(shape)
        self.addSubview(textLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Telegram's «typing» dots in front of a status line
private final class TypingDotsView: UIView {
    private var dots: [UIView] = []

    init(color: UIColor) {
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: 15.0, height: 4.0))
        for i in 0 ..< 3 {
            let dot = UIView(frame: CGRect(x: CGFloat(i) * 5.0, y: 0.0, width: 3.5, height: 3.5))
            dot.backgroundColor = color
            dot.layer.cornerRadius = 1.75
            dot.alpha = 0.3
            self.addSubview(dot)
            self.dots.append(dot)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func play() {
        for (i, dot) in self.dots.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.3, 1.0, 0.3, 0.3]
            animation.keyTimes = [0.0, 0.35, 0.7, 1.0]
            animation.duration = 1.2
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            dot.layer.add(animation, forKey: "typing")
        }
    }

    func stop() {
        for dot in self.dots {
            dot.layer.removeAnimation(forKey: "typing")
        }
    }
}

private func topicIcon(color: UIColor, size: CGFloat, dot: UIColor?, card: UIColor) -> UIView {
    let view = UIView(frame: CGRect(x: 0.0, y: 0.0, width: size, height: size))
    view.backgroundColor = color
    view.layer.cornerRadius = size / 2.0
    let hash = label("#", size: size * 0.5, weight: .bold, color: .white)
    hash.textAlignment = .center
    hash.frame = view.bounds
    view.addSubview(hash)
    if let dot {
        let dotSize: CGFloat = 11.0
        let dotView = UIView(frame: CGRect(x: size - dotSize + 2.5, y: size - dotSize + 2.5, width: dotSize, height: dotSize))
        dotView.backgroundColor = dot
        dotView.layer.cornerRadius = dotSize / 2.0
        dotView.layer.borderWidth = 2.0
        dotView.layer.borderColor = card.cgColor
        view.addSubview(dotView)
    }
    return view
}

private func springIn(_ view: UIView, delay: Double, from: CGAffineTransform) {
    view.alpha = 0.0
    view.transform = from
    UIView.animate(withDuration: 0.5, delay: delay, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
        view.alpha = 1.0
        view.transform = .identity
    })
}

// 1. The icon; its eyes blink
final class AgentgramIntroIconArtwork: AgentgramIntroArtwork {
    private var eyes: [CALayer] = []

    override init(palette: AgentgramIntroPalette) {
        super.init(palette: palette)
        self.setupContent()
        let icon = UIImageView(image: iconImage(eyes: false))
        icon.frame = CGRect(x: 0.0, y: 0.0, width: 200.0, height: 200.0)
        icon.layer.cornerRadius = 45.0
        icon.clipsToBounds = true
        self.content.addSubview(icon)
        // the eyes of the icon (430,478 and 594,478, r 44 of 1024)
        let k: CGFloat = 200.0 / 1024.0
        for x in [430.0, 594.0] as [CGFloat] {
            let eye = CALayer()
            eye.frame = CGRect(x: (x - 44.0) * k, y: (478.0 - 44.0) * k, width: 88.0 * k, height: 88.0 * k)
            let gradient = CAGradientLayer()
            gradient.type = .radial
            gradient.frame = eye.bounds
            gradient.colors = [UIColor(rgb: 0x5AB8FF).cgColor, UIColor(rgb: 0x1563D6).cgColor]
            gradient.startPoint = CGPoint(x: 0.4, y: 0.35)
            gradient.endPoint = CGPoint(x: 1.1, y: 1.05)
            gradient.cornerRadius = eye.bounds.width / 2.0
            gradient.masksToBounds = true
            eye.addSublayer(gradient)
            let highlight = CALayer()
            highlight.frame = CGRect(x: (x - 14.0 - 12.0 - (x - 44.0)) * k, y: (462.0 - 12.0 - (478.0 - 44.0)) * k, width: 24.0 * k, height: 24.0 * k)
            highlight.backgroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
            highlight.cornerRadius = 12.0 * k
            eye.addSublayer(highlight)
            icon.layer.addSublayer(eye)
            self.eyes.append(eye)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func play() {
        for eye in self.eyes {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = [1.0, 1.0, 0.08, 1.0, 1.0]
            animation.keyTimes = [0.0, 0.86, 0.9, 0.94, 1.0]
            animation.duration = 2.6
            animation.repeatCount = .infinity
            eye.add(animation, forKey: "blink")
        }
    }

    override func stop() {
        for eye in self.eyes {
            eye.removeAnimation(forKey: "blink")
        }
    }
}

// 2. A chat: you write, the agent answers
final class AgentgramIntroChatArtwork: AgentgramIntroArtwork {
    private let outgoing: UIView
    private let incoming: UIView

    override init(palette: AgentgramIntroPalette) {
        let ru = AgentgramIntroController.isRussian
        let outgoingBubble = BubbleView(text: ru ? "Собери билд и поставь на телефон" : "Build it and install on my phone", time: "12:40", outgoing: true, palette: palette, maxWidth: 140.0)
        let incomingBubble = BubbleView(text: ru ? "Готово, поставил на iPhone. Можно проверять" : "Done, installed on iPhone. Go ahead and check", time: "12:42", outgoing: false, palette: palette, maxWidth: 140.0)
        self.outgoing = outgoingBubble
        let incoming = UIView()
        let avatar = avatarView(size: 26.0)
        incoming.frame = CGRect(x: 0.0, y: 0.0, width: 26.0 + 6.0 + incomingBubble.bounds.width, height: max(26.0, incomingBubble.bounds.height))
        avatar.frame.origin = CGPoint(x: 0.0, y: incoming.bounds.height - 26.0)
        incomingBubble.frame.origin = CGPoint(x: 32.0, y: incoming.bounds.height - incomingBubble.bounds.height)
        incoming.addSubview(avatar)
        incoming.addSubview(incomingBubble)
        self.incoming = incoming
        super.init(palette: palette)
        self.setupContent()

        let gap: CGFloat = 8.0
        let total = outgoingBubble.bounds.height + gap + incoming.bounds.height
        let top = floor((200.0 - total) / 2.0)
        outgoingBubble.frame.origin = CGPoint(x: 196.0 - outgoingBubble.bounds.width, y: top)
        incoming.frame.origin = CGPoint(x: 4.0, y: top + outgoingBubble.bounds.height + gap)
        self.content.addSubview(outgoingBubble)
        self.content.addSubview(incoming)
        setAnchor(outgoingBubble, CGPoint(x: 1.0, y: 1.0))
        setAnchor(incoming, CGPoint(x: 0.0, y: 1.0))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func play() {
        springIn(self.outgoing, delay: 0.1, from: CGAffineTransform(translationX: 0.0, y: 24.0).scaledBy(x: 0.85, y: 0.85))
        springIn(self.incoming, delay: 0.9, from: CGAffineTransform(translationX: 0.0, y: 20.0).scaledBy(x: 0.85, y: 0.85))
    }
}

private func setAnchor(_ view: UIView, _ anchor: CGPoint) {
    let frame = view.frame
    view.layer.anchorPoint = anchor
    view.frame = frame
}

private final class SessionRow: UIView {
    let typing: TypingDotsView?

    init(palette: AgentgramIntroPalette, width: CGFloat, height: CGFloat, indent: CGFloat, iconSize: CGFloat, color: UIColor, dot: UIColor?, title: String, subtitle: String, typing: Bool) {
        self.typing = typing ? TypingDotsView(color: palette.secondaryText) : nil
        super.init(frame: CGRect(x: 0.0, y: 0.0, width: width, height: height))
        let separator = UIView(frame: CGRect(x: indent, y: 0.0, width: width - indent, height: 0.5))
        separator.backgroundColor = palette.separator
        self.addSubview(separator)
        let icon = topicIcon(color: color, size: iconSize, dot: dot, card: palette.card)
        icon.frame.origin = CGPoint(x: indent, y: floor((height - iconSize) / 2.0))
        self.addSubview(icon)
        let textX = indent + iconSize + 9.0
        let titleLabel = label(title, size: 12.0, weight: .semibold, color: palette.text)
        titleLabel.frame = CGRect(x: textX, y: floor(height / 2.0) - 15.0, width: width - textX - 10.0, height: 15.0)
        self.addSubview(titleLabel)
        var subtitleX = textX
        if let typingView = self.typing {
            typingView.frame.origin = CGPoint(x: textX, y: floor(height / 2.0) + 7.0)
            self.addSubview(typingView)
            subtitleX += 19.0
        }
        let subtitleLabel = label(subtitle, size: 11.0, color: palette.secondaryText)
        subtitleLabel.frame = CGRect(x: subtitleX, y: floor(height / 2.0) + 1.0, width: width - subtitleX - 10.0, height: 14.0)
        self.addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// 3. Sessions under the bot: two work (yellow dot on the topic icon, status line), one is done
final class AgentgramIntroSessionsArtwork: AgentgramIntroArtwork {
    private var rows: [SessionRow] = []

    override init(palette: AgentgramIntroPalette) {
        super.init(palette: palette)
        self.setupContent()
        let ru = AgentgramIntroController.isRussian
        let width: CGFloat = 196.0
        let headerHeight: CGFloat = 50.0
        let rowHeight: CGFloat = 42.0
        let (shadow, card) = cardView(palette: palette, frame: CGRect(x: 2.0, y: floor((200.0 - headerHeight - rowHeight * 3.0) / 2.0), width: width, height: headerHeight + rowHeight * 3.0))
        self.content.addSubview(shadow)

        let avatar = avatarView(size: 34.0)
        avatar.frame.origin = CGPoint(x: 11.0, y: 8.0)
        card.addSubview(avatar)
        let name = label("Claude Worker", size: 13.0, weight: .semibold, color: palette.text)
        name.frame = CGRect(x: 53.0, y: 9.0, width: 130.0, height: 16.0)
        card.addSubview(name)
        let info = label(ru ? "бот · 3 сессии" : "bot · 3 sessions", size: 11.0, color: palette.secondaryText)
        info.frame = CGRect(x: 53.0, y: 26.0, width: 130.0, height: 14.0)
        card.addSubview(info)

        let items: [(UInt32, String, String, Bool)] = [
            (0xFF9500, ru ? "Сборка iOS" : "iOS build", ru ? "запускает команду · 2 мин" : "running a command · 2 min", true),
            (0x34C759, ru ? "Сайт" : "Website", ru ? "правит index.html · 1 мин" : "editing index.html · 1 min", true),
            (0xAF52DE, ru ? "Иконка" : "Icon", ru ? "Вариант А готов" : "Option A is ready", false)
        ]
        for (i, item) in items.enumerated() {
            let row = SessionRow(palette: palette, width: width, height: rowHeight, indent: 28.0, iconSize: 22.0, color: UIColor(rgb: item.0), dot: item.3 ? palette.working : nil, title: item.1, subtitle: item.2, typing: item.3)
            row.frame.origin = CGPoint(x: 0.0, y: headerHeight + CGFloat(i) * rowHeight)
            card.addSubview(row)
            self.rows.append(row)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func play() {
        for (i, row) in self.rows.enumerated() {
            row.alpha = 0.0
            row.transform = CGAffineTransform(translationX: 0.0, y: -10.0)
            UIView.animate(withDuration: 0.45, delay: 0.15 + Double(i) * 0.15, options: [.curveEaseOut], animations: {
                row.alpha = 1.0
                row.transform = .identity
            })
            row.typing?.play()
        }
    }

    override func stop() {
        for row in self.rows {
            row.typing?.stop()
        }
    }
}

// 4. Statuses: thinking (as a working session), waiting for you, done
final class AgentgramIntroStatusesArtwork: AgentgramIntroArtwork {
    private var rows: [SessionRow] = []

    override init(palette: AgentgramIntroPalette) {
        super.init(palette: palette)
        self.setupContent()
        let ru = AgentgramIntroController.isRussian
        let width: CGFloat = 196.0
        let headerHeight: CGFloat = 30.0
        let rowHeight: CGFloat = 46.0
        let (shadow, card) = cardView(palette: palette, frame: CGRect(x: 2.0, y: floor((200.0 - headerHeight - rowHeight * 3.0) / 2.0), width: width, height: headerHeight + rowHeight * 3.0))
        self.content.addSubview(shadow)
        let header = label(ru ? "Сессии" : "Sessions", size: 11.0, weight: .semibold, color: palette.secondaryText)
        header.frame = CGRect(x: 12.0, y: 9.0, width: 150.0, height: 14.0)
        card.addSubview(header)

        let items: [(UInt32, UInt32, String, String, Bool)] = [
            (0xFF9500, 0xF5B70A, ru ? "Сборка iOS" : "iOS build", ru ? "думает · 1 мин" : "thinking · 1 min", true),
            (0x34C759, 0xFF9500, ru ? "Сайт" : "Website", ru ? "ждёт тебя" : "waiting for you", false),
            (0xAF52DE, 0xC7C7CC, ru ? "Иконка" : "Icon", ru ? "готово" : "done", false)
        ]
        for (i, item) in items.enumerated() {
            let row = SessionRow(palette: palette, width: width, height: rowHeight, indent: 12.0, iconSize: 28.0, color: UIColor(rgb: item.0), dot: UIColor(rgb: item.1), title: item.2, subtitle: item.3, typing: item.4)
            row.frame.origin = CGPoint(x: 0.0, y: headerHeight + CGFloat(i) * rowHeight)
            card.addSubview(row)
            self.rows.append(row)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func play() {
        for row in self.rows {
            row.typing?.play()
        }
    }

    override func stop() {
        for row in self.rows {
            row.typing?.stop()
        }
    }
}

// 5. The superfolder: the tab bar flips between Chats and Work, the list slides like a page
final class AgentgramIntroSuperfolderArtwork: AgentgramIntroArtwork {
    private let paneA = UIView()
    private let paneB = UIView()
    private var tabs: [(UIImageView, UILabel)] = []
    private var timer: Timer?
    private var showsWork = false
    private let paneWidth: CGFloat = 196.0

    override init(palette: AgentgramIntroPalette) {
        super.init(palette: palette)
        self.setupContent()
        let ru = AgentgramIntroController.isRussian
        let width = self.paneWidth
        let paneHeight: CGFloat = 112.0
        let tabHeight: CGFloat = 50.0
        let (shadow, card) = cardView(palette: palette, frame: CGRect(x: 2.0, y: floor((200.0 - paneHeight - tabHeight) / 2.0), width: width, height: paneHeight + tabHeight))
        self.content.addSubview(shadow)

        let panes = UIView(frame: CGRect(x: 0.0, y: 0.0, width: width, height: paneHeight))
        panes.clipsToBounds = true
        card.addSubview(panes)
        func fill(_ pane: UIView, title: String, rows: [(UIView, String)]) {
            pane.frame = CGRect(x: 0.0, y: 0.0, width: width, height: paneHeight)
            pane.backgroundColor = palette.card
            let header = label(title, size: 11.0, weight: .semibold, color: palette.secondaryText)
            header.frame = CGRect(x: 12.0, y: 10.0, width: 150.0, height: 14.0)
            pane.addSubview(header)
            for (i, row) in rows.enumerated() {
                let y = 32.0 + CGFloat(i) * 38.0
                row.0.frame.origin = CGPoint(x: 12.0, y: y)
                pane.addSubview(row.0)
                let name = label(row.1, size: 13.0, color: palette.text)
                name.frame = CGRect(x: 52.0, y: y + 8.0, width: 130.0, height: 16.0)
                pane.addSubview(name)
            }
            panes.addSubview(pane)
        }
        func circle(_ rgb: UInt32) -> UIView {
            let view = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 32.0, height: 32.0))
            view.backgroundColor = UIColor(rgb: rgb)
            view.layer.cornerRadius = 16.0
            return view
        }
        fill(self.paneA, title: ru ? "Чаты" : "Chats", rows: [(circle(0xFF8A65), ru ? "Мама" : "Mom"), (circle(0x7986CB), ru ? "Друзья" : "Friends")])
        fill(self.paneB, title: ru ? "Работа" : "Work", rows: [(avatarView(size: 32.0), "Claude Worker"), (circle(0x4DB6AC), ru ? "Команда" : "Team")])
        self.paneB.transform = CGAffineTransform(translationX: width, y: 0.0)

        let tabBar = UIView(frame: CGRect(x: 0.0, y: paneHeight, width: width, height: tabHeight))
        tabBar.backgroundColor = palette.tabBar
        let line = UIView(frame: CGRect(x: 0.0, y: 0.0, width: width, height: 0.5))
        line.backgroundColor = palette.separator
        tabBar.addSubview(line)
        card.addSubview(tabBar)
        let items: [(String, String)] = [("bubble.left.and.bubble.right.fill", ru ? "Чаты" : "Chats"), ("folder.fill", ru ? "Работа" : "Work"), ("gearshape.fill", ru ? "Настройки" : "Settings")]
        for (i, item) in items.enumerated() {
            let x = CGFloat(i) * width / 3.0
            let image = UIImageView(image: UIImage(systemName: item.0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .regular)))
            image.contentMode = .center
            image.frame = CGRect(x: x, y: 6.0, width: width / 3.0, height: 24.0)
            tabBar.addSubview(image)
            let title = label(item.1, size: 9.0, color: palette.secondaryText)
            title.textAlignment = .center
            title.frame = CGRect(x: x, y: 31.0, width: width / 3.0, height: 12.0)
            tabBar.addSubview(title)
            self.tabs.append((image, title))
        }
        self.updateTabs()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateTabs() {
        for (i, tab) in self.tabs.enumerated() {
            let selected = (i == 0 && !self.showsWork) || (i == 1 && self.showsWork)
            let color = selected ? self.palette.accent : self.palette.secondaryText
            tab.0.tintColor = color
            tab.1.textColor = color
        }
    }

    private func flip() {
        self.showsWork = !self.showsWork
        let width = self.paneWidth
        UIView.animate(withDuration: 0.45, delay: 0.0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0.0, options: [], animations: {
            self.paneA.transform = self.showsWork ? CGAffineTransform(translationX: -width, y: 0.0) : .identity
            self.paneB.transform = self.showsWork ? .identity : CGAffineTransform(translationX: width, y: 0.0)
        })
        UIView.transition(with: self.content, duration: 0.2, options: [.transitionCrossDissolve, .allowAnimatedContent], animations: {
            self.updateTabs()
        })
    }

    override func play() {
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true, block: { [weak self] _ in
            self?.flip()
        })
    }

    override func stop() {
        self.timer?.invalidate()
        self.timer = nil
    }
}

// 6. Your computer or your own server, locked
final class AgentgramIntroComputerArtwork: AgentgramIntroArtwork {
    private var tiles: [UIView] = []
    private var timer: Timer?
    private var index = 0

    override init(palette: AgentgramIntroPalette) {
        super.init(palette: palette)
        self.setupContent()
        let ru = AgentgramIntroController.isRussian
        let items: [(String, String)] = [("laptopcomputer", ru ? "Свой компьютер" : "Your computer"), ("server.rack", ru ? "Свой сервер" : "Your server")]
        for (i, item) in items.enumerated() {
            let tile = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 200.0, height: 200.0))
            let square = UIView(frame: CGRect(x: 47.0, y: 28.0, width: 106.0, height: 106.0))
            square.layer.shadowColor = UIColor(rgb: 0x2AABEE).cgColor
            square.layer.shadowOpacity = 0.35
            square.layer.shadowRadius = 11.0
            square.layer.shadowOffset = CGSize(width: 0.0, height: 8.0)
            let gradient = CAGradientLayer()
            gradient.frame = square.bounds
            gradient.colors = [UIColor(rgb: 0x5AC8FA).cgColor, UIColor(rgb: 0x2AABEE).cgColor]
            gradient.cornerRadius = 24.0
            square.layer.addSublayer(gradient)
            let symbol = UIImageView(image: UIImage(systemName: item.0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 48.0, weight: .medium)))
            symbol.tintColor = .white
            symbol.contentMode = .center
            symbol.frame = square.bounds
            square.addSubview(symbol)
            let badge = UIView(frame: CGRect(x: 106.0 - 30.0, y: 106.0 - 30.0, width: 38.0, height: 38.0))
            badge.backgroundColor = UIColor(rgb: 0x34C759)
            badge.layer.cornerRadius = 19.0
            badge.layer.borderWidth = 3.0
            badge.layer.borderColor = (palette.isDark ? UIColor.black : UIColor.white).cgColor
            let lock = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)))
            lock.tintColor = .white
            lock.contentMode = .center
            lock.frame = badge.bounds
            badge.addSubview(lock)
            square.addSubview(badge)
            tile.addSubview(square)
            let caption = label(item.1, size: 13.0, weight: .semibold, color: palette.isDark ? UIColor(rgb: 0xEBEBF5) : UIColor(rgb: 0x3C3C43))
            caption.textAlignment = .center
            caption.frame = CGRect(x: 0.0, y: 150.0, width: 200.0, height: 18.0)
            tile.addSubview(caption)
            tile.alpha = i == 0 ? 1.0 : 0.0
            self.content.addSubview(tile)
            self.tiles.append(tile)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func play() {
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true, block: { [weak self] _ in
            guard let self else {
                return
            }
            let previous = self.tiles[self.index]
            self.index = (self.index + 1) % self.tiles.count
            let next = self.tiles[self.index]
            next.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            UIView.animate(withDuration: 0.4, animations: {
                previous.alpha = 0.0
                previous.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
                next.alpha = 1.0
                next.transform = .identity
            })
        })
    }

    override func stop() {
        self.timer?.invalidate()
        self.timer = nil
    }
}
