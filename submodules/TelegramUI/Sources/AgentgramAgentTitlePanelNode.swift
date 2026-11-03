import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ChatPresentationInterfaceState
import LegacyChatHeaderPanelComponent
import ChatListUI
import AccountContext
import ComponentFlow
import ViewControllerComponent
import SheetComponent
import ButtonComponent
import MultilineTextComponent
import EmojiStatusComponent

// Agentgram: while an agent's session works, a panel stands under the title where the pinned message is: what it
// does, the command, the context and the 5-hour limit, «стоп». A tap opens the sheet with the steps and the limits.
// When the turn ends the panel goes and the pinned message (if any) comes back.
// the work panel and the sheet's context tile when the context is 70% full and more
private let agentgramContextFullColor = UIColor(rgb: 0xFF9500)

final class AgentgramAgentTitlePanelNode: ChatTitleAccessoryPanelNode {
    let context: AccountContext
    let bot: EnginePeer.Id
    let thread: Int64

    private let separatorNode: ASDisplayNode
    private let lineNode: ASDisplayNode
    private let titleNode: ImmediateTextNode
    private let detailNode: ImmediateTextNode
    private let meterNode: ImmediateTextNode
    private let stopButton: HighlightTrackingButtonNode
    private let stopBackgroundNode: ASDisplayNode
    private let stopTitleNode: ImmediateTextNode

    private var disposable: Disposable?
    private var theme: PresentationTheme?
    private var russian = true
    private var title = ""
    private var iconColor: Int32 = 0x6FB9F0
    private var iconFileId: Int64?
    private var lastWidth: (CGFloat, CGFloat, CGFloat)?

    init(context: AccountContext, bot: EnginePeer.Id, thread: Int64) {
        self.context = context
        self.bot = bot
        self.thread = thread

        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true
        self.lineNode = ASDisplayNode()
        self.lineNode.isLayerBacked = true
        self.lineNode.cornerRadius = 1.0
        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 1
        self.detailNode = ImmediateTextNode()
        self.detailNode.maximumNumberOfLines = 1
        self.meterNode = ImmediateTextNode()
        self.meterNode.maximumNumberOfLines = 1
        self.stopButton = HighlightTrackingButtonNode()
        self.stopBackgroundNode = ASDisplayNode()
        self.stopBackgroundNode.isUserInteractionEnabled = false
        self.stopBackgroundNode.cornerRadius = 14.0
        self.stopTitleNode = ImmediateTextNode()
        self.stopTitleNode.isUserInteractionEnabled = false

        super.init()

        self.addSubnode(self.lineNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.detailNode)
        self.addSubnode(self.meterNode)
        self.addSubnode(self.stopBackgroundNode)
        self.addSubnode(self.stopTitleNode)
        self.addSubnode(self.stopButton)
        self.addSubnode(self.separatorNode)

        self.stopButton.addTarget(self, action: #selector(self.stopPressed), forControlEvents: .touchUpInside)
        self.stopButton.highligthedChanged = { [weak self] highlighted in
            self?.stopBackgroundNode.alpha = highlighted ? 0.6 : 1.0
        }

        self.disposable = (AgentgramAgentStatus.sessions
        |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
            self?.updateTexts()
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    override func didLoad() {
        super.didLoad()
        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped)))
    }

    @objc private func stopPressed() {
        AgentgramAgentStatus.stop(bot: self.bot, thread: self.thread)
        self.stopTitleNode.alpha = 0.5
    }

    @objc private func tapped() {
        let screen = AgentgramAgentSheetScreen(context: self.context, bot: self.bot, thread: self.thread, title: self.title, iconColor: self.iconColor, iconFileId: self.iconFileId, russian: self.russian, showsStop: true)
        self.interfaceInteraction?.presentController(screen, nil)
    }

    private func updateTexts() {
        guard let theme = self.theme, let session = AgentgramAgentStatus.session(bot: self.bot, thread: self.thread) else {
            return
        }
        // the context 70% full and more: the panel is orange, as every turn now costs much of the limit
        let full = AgentgramAgentStatus.contextIsFull(session.context)
        let accent = full ? agentgramContextFullColor : theme.rootController.navigationBar.accentTextColor
        let secondary = theme.rootController.navigationBar.secondaryTextColor
        self.lineNode.backgroundColor = accent
        self.stopBackgroundNode.backgroundColor = full ? agentgramContextFullColor : theme.list.itemCheckColors.fillColor
        let now = Int32(Date().timeIntervalSince1970)
        let what = AgentgramAgentStatus.stepText(state: session.state, detail: "", russian: self.russian)
        self.titleNode.attributedText = NSAttributedString(string: "\(what) · \(AgentgramAgentStatus.elapsed(Int(max(0, now - session.since)), russian: self.russian))", font: Font.semibold(14.0), textColor: accent)

        var detail = session.detail
        if detail.isEmpty {
            detail = session.model ?? AgentgramAgentStatus.engines[self.bot] ?? ""
        }
        self.detailNode.attributedText = NSAttributedString(string: detail, font: Font.regular(14.0), textColor: theme.rootController.navigationBar.primaryTextColor)

        var meter: [String] = []
        var contextRange: NSRange?
        if let context = session.context {
            let text = self.russian ? "контекст \(context.used * 100 / context.max)%" : "context \(context.used * 100 / context.max)%"
            if full {
                contextRange = NSRange(location: 0, length: (text as NSString).length)
            }
            meter.append(text)
        }
        let engineName = session.model ?? AgentgramAgentStatus.engines[self.bot]
        if let fiveHour = AgentgramAgentStatus.fiveHour(engineName) {
            meter.append(self.russian ? "5 ч \(fiveHour.pct)%" : "5 h \(fiveHour.pct)%")
        } else if let month = AgentgramAgentStatus.month(engineName) {
            meter.append(self.russian ? "месяц \(month.pct)%" : "month \(month.pct)%")
        }
        if session.queued > 0 {
            meter.append(self.russian ? "в очереди \(session.queued)" : "\(session.queued) queued")
        }
        let meterText = NSMutableAttributedString(attributedString: NSAttributedString(string: meter.joined(separator: "  ·  "), font: Font.regular(12.0), textColor: secondary))
        if let contextRange {
            meterText.addAttributes([.foregroundColor: agentgramContextFullColor, .font: Font.semibold(12.0)], range: contextRange)
        }
        self.meterNode.attributedText = meterText

        if let (width, leftInset, rightInset) = self.lastWidth {
            self.layoutTexts(width: width, leftInset: leftInset, rightInset: rightInset)
        }
    }

    private func layoutTexts(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat) {
        let stopSize = self.stopTitleNode.updateLayout(CGSize(width: 100.0, height: 30.0))
        // the size of the pinned message's button
        let stopWidth = max(stopSize.width + 20.0, 40.0)
        let stopFrame = CGRect(x: width - rightInset - 12.0 - stopWidth, y: floor((AgentgramAgentTitlePanelNode.height - 28.0) / 2.0), width: stopWidth, height: 28.0)
        self.stopBackgroundNode.frame = stopFrame
        self.stopTitleNode.frame = CGRect(origin: CGPoint(x: stopFrame.midX - stopSize.width / 2.0, y: stopFrame.midY - stopSize.height / 2.0), size: stopSize)
        self.stopButton.frame = stopFrame.insetBy(dx: -8.0, dy: -8.0)

        let textX = leftInset + 22.0
        let textWidth = stopFrame.minX - 10.0 - textX
        let titleSize = self.titleNode.updateLayout(CGSize(width: textWidth, height: 20.0))
        let detailSize = self.detailNode.updateLayout(CGSize(width: textWidth, height: 20.0))
        let meterSize = self.meterNode.updateLayout(CGSize(width: textWidth, height: 20.0))
        self.titleNode.frame = CGRect(origin: CGPoint(x: textX, y: 7.0), size: titleSize)
        self.detailNode.frame = CGRect(origin: CGPoint(x: textX, y: 25.0), size: detailSize)
        self.meterNode.frame = CGRect(origin: CGPoint(x: textX, y: 43.0), size: meterSize)
        self.lineNode.frame = CGRect(x: leftInset + 12.0, y: 8.0, width: 2.0, height: AgentgramAgentTitlePanelNode.height - 16.0)
    }

    static let height: CGFloat = 62.0

    override func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
        self.russian = interfaceState.strings.baseLanguageCode == "ru"
        if let info = interfaceState.threadData {
            self.title = info.title
            self.iconColor = info.iconColor
            self.iconFileId = info.icon
        }
        if interfaceState.theme !== self.theme {
            self.theme = interfaceState.theme
            let accent = interfaceState.theme.rootController.navigationBar.accentTextColor
            self.separatorNode.backgroundColor = interfaceState.theme.rootController.navigationBar.separatorColor
            self.lineNode.backgroundColor = accent
            self.stopBackgroundNode.backgroundColor = interfaceState.theme.list.itemCheckColors.fillColor
            self.stopTitleNode.attributedText = NSAttributedString(string: self.russian ? "СТОП" : "STOP", font: Font.with(size: 15.0, design: .round, weight: .semibold), textColor: interfaceState.theme.list.itemCheckColors.foregroundColor)
        }
        self.lastWidth = (width, leftInset, rightInset)
        self.updateTexts()
        self.layoutTexts(width: width, leftInset: leftInset, rightInset: rightInset)
        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: AgentgramAgentTitlePanelNode.height - UIScreenPixel), size: CGSize(width: width, height: UIScreenPixel)))
        return LayoutResult(backgroundHeight: AgentgramAgentTitlePanelNode.height, insetHeight: AgentgramAgentTitlePanelNode.height, hitTestSlop: 0.0)
    }
}

// the sheet (Telegram's own), like a profile card: the session's icon with its dot, its name and what it does; three
// tiles (context, 5 h, 7 d with when they reset); the turn's steps; «СТОП»
private final class AgentgramAgentSheetContent: CombinedComponent {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let bot: EnginePeer.Id
    let thread: Int64
    let title: String
    let icon: AgentgramSheetIcon
    let russian: Bool
    let showsStop: Bool
    let dismiss: () -> Void

    init(bot: EnginePeer.Id, thread: Int64, title: String, icon: AgentgramSheetIcon, russian: Bool, showsStop: Bool, dismiss: @escaping () -> Void) {
        self.bot = bot
        self.thread = thread
        self.title = title
        self.icon = icon
        self.russian = russian
        self.showsStop = showsStop
        self.dismiss = dismiss
    }

    static func ==(lhs: AgentgramAgentSheetContent, rhs: AgentgramAgentSheetContent) -> Bool {
        return lhs.bot == rhs.bot && lhs.thread == rhs.thread && lhs.title == rhs.title && lhs.russian == rhs.russian
    }

    // follows the server every second, so the sheet counts and its steps grow
    final class State: ComponentState {
        var tick = 0
        private var disposable: Disposable?

        override init() {
            super.init()
            self.disposable = (AgentgramAgentStatus.sessions
            |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
                guard let self else {
                    return
                }
                self.tick += 1
                self.updated(transition: .immediate)
            })
        }

        deinit {
            self.disposable?.dispose()
        }
    }

    func makeState() -> State {
        return State()
    }

    static var body: Body {
        let card = Child(AgentgramAgentSheetCard.self)
        let stopButton = Child(ButtonComponent.self)
        let compactButton = Child(ButtonComponent.self)

        return { context in
            let environment = context.environment[EnvironmentType.self]
            let component = context.component
            let theme = environment.theme

            var contentHeight: CGFloat = 24.0
            let card = card.update(
                component: AgentgramAgentSheetCard(bot: component.bot, thread: component.thread, title: component.title, icon: component.icon, russian: component.russian, theme: theme, tick: context.state.tick),
                availableSize: CGSize(width: context.availableSize.width - 24.0 - environment.safeInsets.left - environment.safeInsets.right, height: 10000.0),
                transition: .immediate
            )
            context.add(card
                .position(CGPoint(x: context.availableSize.width / 2.0, y: contentHeight + card.size.height / 2.0))
            )
            contentHeight += card.size.height + 16.0

            // «СТОП» only from the work panel, and only while the turn goes; «Сжать сессию» whenever the context is known
            let buttonInsets = ContainerViewLayout.concentricInsets(bottomInset: environment.safeInsets.bottom, innerDiameter: 52.0, sideInset: 30.0)
            let session = AgentgramAgentStatus.session(bot: component.bot, thread: component.thread)
            let showsStop = component.showsStop && (session?.working ?? false)
            let showsCompact = session?.context != nil && session?.detail != "Сжимаю сессию"
            if !showsStop && !showsCompact {
                return CGSize(width: context.availableSize.width, height: contentHeight + buttonInsets.bottom)
            }
            if showsStop {
                let stopTitle = NSAttributedString(string: component.russian ? "СТОП" : "STOP", font: Font.semibold(17.0), textColor: theme.list.itemCheckColors.foregroundColor, paragraphAlignment: .center)
                let stopButton = stopButton.update(
                    component: ButtonComponent(
                        background: ButtonComponent.Background(
                            style: .glass,
                            color: theme.list.itemCheckColors.fillColor,
                            foreground: theme.list.itemCheckColors.foregroundColor,
                            pressedColor: theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.9)
                        ),
                        content: AnyComponentWithIdentity(id: AnyHashable(0), component: AnyComponent(MultilineTextComponent(text: .plain(stopTitle)))),
                        isEnabled: true,
                        displaysProgress: false,
                        action: {
                            AgentgramAgentStatus.stop(bot: component.bot, thread: component.thread)
                            component.dismiss()
                        }
                    ),
                    availableSize: CGSize(width: context.availableSize.width - buttonInsets.left - buttonInsets.right, height: 52.0),
                    transition: context.transition
                )
                context.add(stopButton
                    .position(CGPoint(x: context.availableSize.width / 2.0, y: contentHeight + stopButton.size.height / 2.0))
                )
                contentHeight += stopButton.size.height
            }
            if showsCompact {
                if showsStop {
                    contentHeight += 10.0
                }
                // orange when the context is 70% full and more, as the panel
                let full = AgentgramAgentStatus.contextIsFull(session?.context)
                let fill = full ? agentgramContextFullColor : theme.list.itemCheckColors.fillColor
                let compactTitle = NSAttributedString(string: component.russian ? "Сжать сессию" : "Compact session", font: Font.semibold(17.0), textColor: theme.list.itemCheckColors.foregroundColor, paragraphAlignment: .center)
                let compactButton = compactButton.update(
                    component: ButtonComponent(
                        background: ButtonComponent.Background(
                            style: .glass,
                            color: fill,
                            foreground: theme.list.itemCheckColors.foregroundColor,
                            pressedColor: fill.withMultipliedAlpha(0.9)
                        ),
                        content: AnyComponentWithIdentity(id: AnyHashable(1), component: AnyComponent(MultilineTextComponent(text: .plain(compactTitle)))),
                        isEnabled: true,
                        displaysProgress: false,
                        action: {
                            AgentgramAgentStatus.compact(bot: component.bot, thread: component.thread)
                            component.dismiss()
                        }
                    ),
                    availableSize: CGSize(width: context.availableSize.width - buttonInsets.left - buttonInsets.right, height: 52.0),
                    transition: context.transition
                )
                context.add(compactButton
                    .position(CGPoint(x: context.availableSize.width / 2.0, y: contentHeight + compactButton.size.height / 2.0))
                )
                contentHeight += compactButton.size.height
            }
            contentHeight += buttonInsets.bottom

            return CGSize(width: context.availableSize.width, height: contentHeight)
        }
    }
}

// the card itself: plain views laid out by a stack, sized to its content
private final class AgentgramAgentSheetCard: Component {
    let bot: EnginePeer.Id
    let thread: Int64
    let title: String
    let icon: AgentgramSheetIcon
    let russian: Bool
    let theme: PresentationTheme
    let tick: Int

    init(bot: EnginePeer.Id, thread: Int64, title: String, icon: AgentgramSheetIcon, russian: Bool, theme: PresentationTheme, tick: Int) {
        self.bot = bot
        self.thread = thread
        self.title = title
        self.icon = icon
        self.russian = russian
        self.theme = theme
        self.tick = tick
    }

    static func ==(lhs: AgentgramAgentSheetCard, rhs: AgentgramAgentSheetCard) -> Bool {
        return lhs.bot == rhs.bot && lhs.thread == rhs.thread && lhs.title == rhs.title && lhs.russian == rhs.russian && lhs.theme === rhs.theme && lhs.tick == rhs.tick
    }

    final class View: UIView {
        private let content = UIStackView()
        // the topic's own icon (its emoji, or the coloured letter), kept between updates so the emoji plays on
        private let iconWrap = UIView()
        private let iconHost = ComponentHostView<Empty>()
        private let dot = UIView()
        private var iconSet = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.content.axis = .vertical
            self.content.spacing = 6.0
            self.addSubview(self.content)

            self.iconHost.translatesAutoresizingMaskIntoConstraints = false
            self.dot.translatesAutoresizingMaskIntoConstraints = false
            self.dot.backgroundColor = UIColor(rgb: 0xf5b70a)
            self.dot.layer.cornerRadius = 11.0
            self.dot.layer.borderWidth = 3.0
            self.iconWrap.addSubview(self.iconHost)
            self.iconWrap.addSubview(self.dot)
            NSLayoutConstraint.activate([
                self.iconHost.widthAnchor.constraint(equalToConstant: 72.0),
                self.iconHost.heightAnchor.constraint(equalToConstant: 72.0),
                self.iconHost.centerXAnchor.constraint(equalTo: self.iconWrap.centerXAnchor),
                self.iconHost.topAnchor.constraint(equalTo: self.iconWrap.topAnchor),
                self.iconHost.bottomAnchor.constraint(equalTo: self.iconWrap.bottomAnchor),
                self.dot.widthAnchor.constraint(equalToConstant: 22.0),
                self.dot.heightAnchor.constraint(equalToConstant: 22.0),
                self.dot.trailingAnchor.constraint(equalTo: self.iconHost.trailingAnchor, constant: 2.0),
                self.dot.bottomAnchor.constraint(equalTo: self.iconHost.bottomAnchor, constant: 2.0)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(component: AgentgramAgentSheetCard, availableSize: CGSize) -> CGSize {
            for view in self.content.arrangedSubviews where view !== self.iconWrap {
                view.removeFromSuperview()
            }
            let builder = AgentgramAgentSheetBuilder(theme: component.theme, russian: component.russian, bot: component.bot)
            let session = AgentgramAgentStatus.session(bot: component.bot, thread: component.thread)
            let icon = component.icon
            let content: EmojiStatusComponent.Content
            if let fileId = icon.fileId, fileId != 0 {
                content = .animation(content: .customEmoji(fileId: fileId), size: CGSize(width: 72.0, height: 72.0), placeholderColor: component.theme.list.mediaPlaceholderColor, themeColor: component.theme.list.itemAccentColor, loopMode: .count(0))
            } else {
                content = .topic(title: String(component.title.prefix(1)), color: icon.color, size: CGSize(width: 72.0, height: 72.0))
            }
            if !self.iconSet {
                self.iconSet = true
                let _ = self.iconHost.update(
                transition: .immediate,
                component: AnyComponent(EmojiStatusComponent(context: icon.context, animationCache: icon.context.animationCache, animationRenderer: icon.context.animationRenderer, content: content, isVisibleForAnimations: true, action: nil)),
                environment: {},
                containerSize: CGSize(width: 72.0, height: 72.0)
                )
            }
            self.dot.isHidden = session?.working != true
            self.dot.layer.borderColor = component.theme.list.blocksBackgroundColor.cgColor
            for view in builder.views(session: session, title: component.title, iconView: self.iconWrap) where view !== self.iconWrap {
                self.content.addArrangedSubview(view)
            }
            if self.iconWrap.superview == nil {
                self.content.insertArrangedSubview(self.iconWrap, at: 0)
            }
            if let last = self.content.arrangedSubviews.first {
                self.content.setCustomSpacing(10.0, after: last)
            }
            let size = self.content.systemLayoutSizeFitting(CGSize(width: availableSize.width, height: 0.0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            self.content.frame = CGRect(origin: CGPoint(), size: CGSize(width: availableSize.width, height: size.height))
            return CGSize(width: availableSize.width, height: size.height)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize)
    }
}

private struct AgentgramAgentSheetBuilder {
    let theme: PresentationTheme
    let russian: Bool
    let bot: EnginePeer.Id

    func views(session: AgentgramAgentStatus.Session?, title: String, iconView: UIView) -> [UIView] {
        let list = self.theme.list
        var result: [UIView] = []

        result.append(iconView)

        result.append(self.label(title, size: 20.0, weight: .bold, color: list.itemPrimaryTextColor, center: true))

        let now = Int32(Date().timeIntervalSince1970)
        let subtitle: String
        var elapsed = ""
        if let session, session.working {
            elapsed = AgentgramAgentStatus.elapsed(Int(max(0, now - session.since)), russian: self.russian)
            subtitle = "\(AgentgramAgentStatus.stepText(state: session.state, detail: "", russian: self.russian)) · \(elapsed)"
        } else if let session {
            subtitle = AgentgramAgentStatus.text(session, russian: self.russian)
        } else {
            subtitle = self.russian ? "ждёт сообщения" : "waiting for a message"
        }
        let subtitleLabel = self.label(subtitle, size: 15.0, weight: .regular, color: list.itemAccentColor, center: true)
        result.append(subtitleLabel)

        var tiles: [UIView] = []
        if let context = session?.context {
            let total = context.max >= 1000000 ? "\(context.max / 1000000)M" : "\(context.max / 1000)k"
            tiles.append(self.tile(self.russian ? "контекст" : "context", "\(context.used * 100 / context.max)%", "\(context.used / 1000)k " + (self.russian ? "из " : "of ") + total, full: AgentgramAgentStatus.contextIsFull(context)))
        }
        // the limits of this session's engine, named, so Claude Code's are not taken for Codex's
        let engineName = session?.model ?? AgentgramAgentStatus.engines[self.bot] ?? "Claude Code"
        if let limit = AgentgramAgentStatus.fiveHour(engineName) {
            tiles.append(self.tile((self.russian ? "5 ч · " : "5 h · ") + engineName, "\(limit.pct)%", self.resetText(limit.resetsAt)))
        }
        if let limit = AgentgramAgentStatus.week(engineName) {
            tiles.append(self.tile((self.russian ? "неделя · " : "week · ") + engineName, "\(limit.pct)%", self.resetText(limit.resetsAt)))
        }
        if let limit = AgentgramAgentStatus.month(engineName) {
            tiles.append(self.tile((self.russian ? "месяц · " : "month · ") + engineName, "\(limit.pct)%", self.resetText(limit.resetsAt)))
        }
        if !tiles.isEmpty {
            let row = UIStackView(arrangedSubviews: tiles)
            row.axis = .horizontal
            row.spacing = 8.0
            row.distribution = .fillEqually
            let wrap = UIStackView(arrangedSubviews: [row])
            wrap.isLayoutMarginsRelativeArrangement = true
            wrap.layoutMargins = UIEdgeInsets(top: 10.0, left: 0.0, bottom: 0.0, right: 0.0)
            result.append(wrap)
        }

        var rows: [(String, String, String, Bool)] = (session?.steps ?? []).map { ($0.state, $0.detail, $0.secs > 0 ? AgentgramAgentStatus.elapsed($0.secs, russian: self.russian) : "", false) }
        if let session, session.working {
            rows.append((session.state, session.detail, elapsed, true))
        }
        if !rows.isEmpty {
            var header = self.russian ? "ШАГИ" : "STEPS"
            if let model = session?.model {
                header += " · " + model.uppercased()
            }
            let headerLabel = self.label(header, size: 13.0, weight: .regular, color: list.freeTextColor, center: false)
            let headerWrap = UIStackView(arrangedSubviews: [headerLabel])
            headerWrap.isLayoutMarginsRelativeArrangement = true
            headerWrap.layoutMargins = UIEdgeInsets(top: 12.0, left: 16.0, bottom: 2.0, right: 16.0)
            result.append(headerWrap)

            let group = UIStackView()
            group.axis = .vertical
            group.backgroundColor = list.itemBlocksBackgroundColor
            group.layer.cornerRadius = 22.0
            group.layer.cornerCurve = .continuous
            group.clipsToBounds = true
            for (i, row) in rows.enumerated() {
                group.addArrangedSubview(self.stepRow(state: row.0, detail: row.1, time: row.2, current: row.3, last: i == rows.count - 1))
            }
            result.append(group)
        }
        return result
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, center: Bool) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.textAlignment = center ? .center : .natural
        label.numberOfLines = 1
        return label
    }

    // «сброс 19:40», «сброс пн 10:00»
    private func resetText(_ at: Int32?) -> String {
        guard let at else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: self.russian ? "ru_RU" : "en_US")
        let date = Date(timeIntervalSince1970: TimeInterval(at))
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EE HH:mm"
        return (self.russian ? "сброс " : "resets ") + formatter.string(from: date)
    }

    private func tile(_ title: String, _ value: String, _ caption: String, full: Bool = false) -> UIView {
        let list = self.theme.list
        let captionLabel = self.label(caption, size: 11.5, weight: .regular, color: list.itemSecondaryTextColor, center: false)
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.8
        let stack = UIStackView(arrangedSubviews: [
            self.label(title, size: 12.0, weight: .regular, color: list.itemSecondaryTextColor, center: false),
            self.label(value, size: 22.0, weight: .bold, color: full ? agentgramContextFullColor : list.itemPrimaryTextColor, center: false),
            captionLabel
        ])
        stack.axis = .vertical
        stack.spacing = 2.0
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12.0, left: 16.0, bottom: 12.0, right: 10.0)
        stack.backgroundColor = list.itemBlocksBackgroundColor
        stack.layer.cornerRadius = 22.0
        stack.layer.cornerCurve = .continuous
        if full {
            stack.layer.borderWidth = 2.0
            stack.layer.borderColor = agentgramContextFullColor.cgColor
        }
        return stack
    }

    private func stepRow(state: String, detail: String, time: String, current: Bool, last: Bool) -> UIView {
        let list = self.theme.list
        let symbol: String
        let color: UIColor
        switch state {
        case "thinking":
            symbol = "brain"
            color = UIColor(rgb: 0x8e8e93)
        case "reading":
            symbol = "doc.text"
            color = UIColor(rgb: 0x5ac8fa)
        case "editing":
            symbol = "pencil"
            color = UIColor(rgb: 0xff9500)
        case "running":
            symbol = "terminal"
            color = UIColor(rgb: 0x2481cc)
        case "searching":
            symbol = "magnifyingglass"
            color = UIColor(rgb: 0x34c759)
        default:
            symbol = "circle"
            color = UIColor(rgb: 0x8e8e93)
        }
        let iconView = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)))
        iconView.tintColor = .white
        iconView.contentMode = .center
        iconView.backgroundColor = color
        iconView.layer.cornerRadius = 7.0
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 28.0), iconView.heightAnchor.constraint(equalToConstant: 28.0)])

        let text = self.label(state == "running" && !detail.isEmpty ? detail : AgentgramAgentStatus.stepText(state: state, detail: detail, russian: self.russian), size: 16.0, weight: .regular, color: current ? list.itemAccentColor : list.itemPrimaryTextColor, center: false)
        text.lineBreakMode = .byTruncatingMiddle
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let timeLabel = self.label(time, size: 16.0, weight: .regular, color: list.itemSecondaryTextColor, center: false)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconView, text, timeLabel])
        row.axis = .horizontal
        row.spacing = 12.0
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 8.0, left: 14.0, bottom: 8.0, right: 14.0)
        if !last {
            let separator = UIView()
            separator.backgroundColor = list.itemBlocksSeparatorColor
            separator.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(separator)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 54.0),
                separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                separator.heightAnchor.constraint(equalToConstant: UIScreenPixel)
            ])
        }
        return row
    }
}

private final class AgentgramAgentSheetContainer: CombinedComponent {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let bot: EnginePeer.Id
    let thread: Int64
    let title: String
    let icon: AgentgramSheetIcon
    let russian: Bool
    let showsStop: Bool

    init(bot: EnginePeer.Id, thread: Int64, title: String, icon: AgentgramSheetIcon, russian: Bool, showsStop: Bool) {
        self.bot = bot
        self.thread = thread
        self.title = title
        self.icon = icon
        self.russian = russian
        self.showsStop = showsStop
    }

    static func ==(lhs: AgentgramAgentSheetContainer, rhs: AgentgramAgentSheetContainer) -> Bool {
        return lhs.bot == rhs.bot && lhs.thread == rhs.thread && lhs.title == rhs.title && lhs.russian == rhs.russian
    }

    static var body: Body {
        let sheet = Child(SheetComponent<EnvironmentType>.self)
        let animateOut = StoredActionSlot(Action<Void>.self)
        let sheetExternalState = SheetComponent<EnvironmentType>.ExternalState()

        return { context in
            let environment = context.environment[EnvironmentType.self]
            let controller = environment.controller
            let component = context.component

            let sheet = sheet.update(
                component: SheetComponent<EnvironmentType>(
                    content: AnyComponent<EnvironmentType>(AgentgramAgentSheetContent(
                        bot: component.bot,
                        thread: component.thread,
                        title: component.title,
                        icon: component.icon,
                        russian: component.russian,
                        showsStop: component.showsStop,
                        dismiss: {
                            animateOut.invoke(Action { _ in
                                if let controller = controller() {
                                    controller.dismiss(completion: nil)
                                }
                            })
                        }
                    )),
                    style: .glass,
                    backgroundColor: .color(environment.theme.list.blocksBackgroundColor),
                    followContentSizeChanges: true,
                    externalState: sheetExternalState,
                    animateOut: animateOut
                ),
                environment: {
                    environment
                    SheetComponentEnvironment(
                        metrics: environment.metrics,
                        deviceMetrics: environment.deviceMetrics,
                        isDisplaying: environment.value.isVisible,
                        isCentered: environment.presentsFloatingPanels,
                        hasInputHeight: !environment.inputHeight.isZero,
                        regularMetricsSize: CGSize(width: 430.0, height: 900.0),
                        dismiss: { animated in
                            if animated {
                                animateOut.invoke(Action { _ in
                                    if let controller = controller() {
                                        controller.dismiss(completion: nil)
                                    }
                                })
                            } else {
                                if let controller = controller() {
                                    controller.dismiss(completion: nil)
                                }
                            }
                        }
                    )
                },
                availableSize: context.availableSize,
                transition: context.transition
            )
            context.add(sheet
                .position(CGPoint(x: context.availableSize.width / 2.0, y: context.availableSize.height / 2.0))
            )
            return context.availableSize
        }
    }
}

final class AgentgramAgentSheetScreen: ViewControllerComponentContainer {
    init(context: AccountContext, bot: EnginePeer.Id, thread: Int64, title: String, iconColor: Int32, iconFileId: Int64?, russian: Bool, showsStop: Bool) {
        super.init(
            context: context,
            component: AgentgramAgentSheetContainer(bot: bot, thread: thread, title: title, icon: AgentgramSheetIcon(context: context, color: iconColor, fileId: iconFileId), russian: russian, showsStop: showsStop),
            navigationBarAppearance: .none,
            statusBarStyle: .ignore,
            theme: .default
        )
        self.navigationPresentation = .flatModal
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// what the sheet draws as the session's icon: the topic's emoji, or Telegram's coloured topic letter
private final class AgentgramSheetIcon {
    let context: AccountContext
    let color: Int32
    let fileId: Int64?

    init(context: AccountContext, color: Int32, fileId: Int64?) {
        self.context = context
        self.color = color
        self.fileId = fileId
    }
}
