import Foundation
import UIKit
import SSignalKit
import RMIntro
import AppBundle

// Agentgram: the welcome screen before login, in place of Telegram's RMIntroViewController. The same contract
// (pages, dots, the start button made by the splash, «Continue in …», snapshots for the transition to the phone
// screen); the pages are about agents, with pictures built from the app's own elements, and the texts live here,
// in Russian and English, so the server's language pack cannot replace them.
public final class AgentgramIntroController: UIViewController, UIScrollViewDelegate {
    // Like Telegram's intro, the pages are in English; «Continue in Russian» under the button switches the app's
    // language. The Russian texts are kept for when the intro follows the app's language.
    public static var isRussian: Bool {
        return false
    }

    public static var startButtonTitle: String {
        return isRussian ? "Начать" : "Start"
    }

    public var defaultFrame: CGRect = CGRect()
    public var startMessaging: (() -> Void)?
    public var startMessagingInAlternativeLanguage: ((String?) -> Void)?
    public var createStartButton: ((CGFloat) -> UIView?)?
    public var isEnabled: Bool = true {
        didSet {
            self.alternativeLanguageButton.alpha = self.isEnabled ? 1.0 : 0.6
        }
    }

    private let backgroundColor: UIColor
    private let primaryColor: UIColor
    private let accentColor: UIColor
    private let regularDotColor: UIColor
    private let highlightedDotColor: UIColor
    private let palette: AgentgramIntroPalette

    private let pages: [(title: String, text: String)]
    private var artworks: [AgentgramIntroArtwork] = []
    private let artworkContainer = UIView()
    private let wrapperView = UIView()
    private let scrollView = UIScrollView()
    private var pageViews: [AgentgramIntroPageView] = []
    private let pageControl = UIPageControl()
    private let alternativeLanguageButton = UIButton(type: .system)
    private weak var startButton: UIView?

    private var currentPage = 0
    private var localizationsDisposable: SDisposable?
    private var alternativeLanguageCode: String?
    private var loadedView = false

    public init(backgroundColor: UIColor, primaryColor: UIColor, accentColor: UIColor, regularDotColor: UIColor, highlightedDotColor: UIColor, suggestedLocalizationSignal: SSignal) {
        self.backgroundColor = backgroundColor
        self.primaryColor = primaryColor
        self.accentColor = accentColor
        self.regularDotColor = regularDotColor
        self.highlightedDotColor = highlightedDotColor
        self.palette = AgentgramIntroPalette(background: backgroundColor)
        self.pages = AgentgramIntroController.isRussian ? AgentgramIntroTexts.russian : AgentgramIntroTexts.english

        super.init(nibName: nil, bundle: nil)

        self.alternativeLanguageButton.setTitleColor(accentColor, for: .normal)
        self.alternativeLanguageButton.titleLabel?.font = UIFont.systemFont(ofSize: 18.0)
        self.alternativeLanguageButton.isHidden = true
        self.alternativeLanguageButton.addTarget(self, action: #selector(self.alternativeLanguagePressed), for: .touchUpInside)

        self.localizationsDisposable = suggestedLocalizationSignal.start(next: { [weak self] next in
            DispatchQueue.main.async {
                self?.suggestedLocalizationReceived(next as? TGSuggestedLocalization)
            }
        })
    }

    private func suggestedLocalizationReceived(_ localization: TGSuggestedLocalization?) {
        guard let localization, self.alternativeLanguageCode == nil else {
            return
        }
        self.alternativeLanguageCode = localization.info.code
        self.alternativeLanguageButton.setTitle(localization.continueWithLanguageString, for: .normal)
        self.alternativeLanguageButton.sizeToFit()
        self.alternativeLanguageButton.isHidden = false
        if self.isViewLoaded {
            self.alternativeLanguageButton.alpha = 0.0
            UIView.animate(withDuration: 0.3, animations: {
                self.alternativeLanguageButton.alpha = self.isEnabled ? 1.0 : 0.6
                self.updateLayout()
            })
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.localizationsDisposable?.dispose()
    }

    override public func loadView() {
        let view = AgentgramIntroView(frame: self.defaultFrame)
        view.onLayout = { [weak self] in
            self?.updateLayout()
        }
        self.view = view
        self.viewDidLoad()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        if self.loadedView {
            return
        }
        self.loadedView = true

        self.view.backgroundColor = self.backgroundColor

        self.artworks = [
            AgentgramIntroIconArtwork(palette: self.palette),
            AgentgramIntroChatArtwork(palette: self.palette),
            AgentgramIntroSessionsArtwork(palette: self.palette),
            AgentgramIntroStatusesArtwork(palette: self.palette),
            AgentgramIntroSuperfolderArtwork(palette: self.palette),
            AgentgramIntroComputerArtwork(palette: self.palette)
        ]
        self.artworkContainer.isUserInteractionEnabled = false
        for artwork in self.artworks {
            artwork.alpha = 0.0
            self.artworkContainer.addSubview(artwork)
        }
        self.view.addSubview(self.artworkContainer)

        self.view.addSubview(self.wrapperView)
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.isPagingEnabled = true
        self.scrollView.delegate = self
        self.wrapperView.addSubview(self.scrollView)

        for page in self.pages {
            let pageView = AgentgramIntroPageView(title: page.title, text: page.text, color: self.primaryColor)
            self.pageViews.append(pageView)
            self.scrollView.addSubview(pageView)
        }

        self.view.addSubview(self.alternativeLanguageButton)

        self.pageControl.isUserInteractionEnabled = false
        self.pageControl.numberOfPages = self.pages.count
        self.pageControl.pageIndicatorTintColor = self.regularDotColor
        self.pageControl.currentPageIndicatorTintColor = self.highlightedDotColor
        self.wrapperView.addSubview(self.pageControl)

        self.updateArtworks()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.artworks[self.currentPage].play()
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        for artwork in self.artworks {
            artwork.stop()
        }
    }

    public func animateIn() {
        let artworkTarget = self.artworkContainer.center
        self.artworkContainer.center = CGPoint(x: self.view.bounds.width / 2.0, y: self.view.bounds.height / 2.0)
        self.artworkContainer.transform = CGAffineTransform(scaleX: 0.66, y: 0.66)

        let firstPage = self.pageViews[0]
        let titleTarget = firstPage.titleLabel.center
        firstPage.titleLabel.center = CGPoint(x: titleTarget.x, y: titleTarget.y + 140.0)
        let textTarget = firstPage.textLabel.center
        firstPage.textLabel.center = CGPoint(x: textTarget.x, y: textTarget.y + 160.0)
        let pageControlTarget = self.pageControl.center
        self.pageControl.center = CGPoint(x: pageControlTarget.x, y: pageControlTarget.y + 200.0)
        let buttonTarget = self.startButton?.center ?? CGPoint()
        self.startButton?.center = CGPoint(x: buttonTarget.x, y: buttonTarget.y + 220.0)

        UIView.animate(withDuration: 0.65, delay: 0.15, usingSpringWithDamping: 1.2, initialSpringVelocity: 0.0, options: [], animations: {
            self.artworkContainer.center = artworkTarget
            self.artworkContainer.transform = .identity
            firstPage.titleLabel.center = titleTarget
            firstPage.textLabel.center = textTarget
            self.pageControl.center = pageControlTarget
            self.startButton?.center = buttonTarget
        })

        self.artworkContainer.alpha = 0.0
        self.scrollView.alpha = 0.0
        self.pageControl.alpha = 0.0
        self.startButton?.alpha = 0.0
        UIView.animate(withDuration: 0.3, delay: 0.15, options: [], animations: {
            self.artworkContainer.alpha = 1.0
            self.scrollView.alpha = 1.0
            self.pageControl.alpha = 1.0
            self.startButton?.alpha = 1.0
        })
    }

    public func createAnimationSnapshot() -> UIView? {
        guard let snapshot = self.artworkContainer.snapshotView(afterScreenUpdates: false) else {
            return nil
        }
        snapshot.frame = self.artworkContainer.frame
        return snapshot
    }

    public func createTextSnapshot() -> UIView? {
        guard let snapshot = self.wrapperView.snapshotView(afterScreenUpdates: false) else {
            return nil
        }
        snapshot.frame = self.wrapperView.frame
        return snapshot
    }

    // The same positions as Telegram's intro, by screen height
    private func updateLayout() {
        let size = self.view.bounds.size
        if size.width.isZero {
            return
        }
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isVertical = size.height / size.width > 1.0
        let height = max(size.width, size.height)

        let artworkY: CGFloat
        var startButtonY: CGFloat
        let pageY: CGFloat
        var languageButtonSpread: CGFloat = 60.0
        var languageButtonOffset: CGFloat = 26.0
        if isPad {
            artworkY = height >= 1366.0 ? (isVertical ? 221.0 + 110.0 : 221.0) : (isVertical ? 121.0 + 90.0 : 121.0)
            startButtonY = 120.0
            pageY = height >= 1366.0 ? (isVertical ? 605.0 : 435.0) : (isVertical ? 485.0 : 335.0)
        } else if height <= 568.0 {
            artworkY = 62.0
            startButtonY = 75.0
            pageY = 245.0
            languageButtonSpread = 50.0
            languageButtonOffset = 20.0
        } else if height <= 667.0 {
            artworkY = 62.0 + 25.0
            startButtonY = 75.0 + 5.0
            pageY = 245.0 + 50.0
        } else if height >= 896.0 {
            artworkY = 62.0 + 85.0
            startButtonY = 75.0 + 30.0
            pageY = 245.0 + 125.0
        } else {
            artworkY = 62.0 + 45.0
            startButtonY = 75.0 + 20.0
            pageY = 245.0 + 85.0
        }
        let pageControlY = pageY + (isPad ? 200.0 : 160.0)
        if !self.alternativeLanguageButton.isHidden {
            startButtonY += languageButtonSpread
        }

        let artworkSize: CGFloat = isPad ? 240.0 : 200.0
        self.artworkContainer.bounds = CGRect(origin: CGPoint(), size: CGSize(width: artworkSize, height: artworkSize))
        if self.artworkContainer.transform.isIdentity {
            self.artworkContainer.center = CGPoint(x: size.width / 2.0, y: artworkY + artworkSize / 2.0)
        }
        for artwork in self.artworks {
            artwork.frame = self.artworkContainer.bounds
        }

        self.pageControl.frame = CGRect(x: 0.0, y: pageControlY, width: size.width, height: 7.0)

        let startButtonWidth = min(430.0 - 48.0, size.width - 48.0)
        if let startButton = self.createStartButton?(startButtonWidth) {
            if startButton.superview == nil {
                self.startButton = startButton
                self.view.addSubview(startButton)
            }
            startButton.frame = CGRect(x: floor((size.width - startButtonWidth) / 2.0), y: size.height - startButtonY, width: startButtonWidth, height: 50.0)
            let languageSize = self.alternativeLanguageButton.frame.size
            self.alternativeLanguageButton.frame = CGRect(x: floor((size.width - languageSize.width) / 2.0), y: startButton.frame.maxY + languageButtonOffset, width: languageSize.width, height: languageSize.height)
        }

        self.wrapperView.frame = CGRect(origin: CGPoint(), size: size)
        self.scrollView.frame = CGRect(x: 0.0, y: 20.0, width: size.width, height: size.height - 20.0)
        self.scrollView.contentSize = CGSize(width: CGFloat(self.pages.count) * size.width, height: 150.0)
        self.scrollView.contentOffset = CGPoint(x: CGFloat(self.currentPage) * size.width, y: 0.0)
        for (index, pageView) in self.pageViews.enumerated() {
            pageView.frame = CGRect(x: CGFloat(index) * size.width, y: pageY, width: size.width, height: 150.0)
        }
        self.updateArtworks()
    }

    // The pictures stay in place above the pages: the one of the page under the finger fades in as it comes
    private func updateArtworks() {
        let width = max(1.0, self.scrollView.bounds.width)
        let position = self.scrollView.contentOffset.x / width
        for (index, artwork) in self.artworks.enumerated() {
            let distance = abs(position - CGFloat(index))
            let alpha = max(0.0, 1.0 - distance * 1.6)
            artwork.alpha = alpha
            let scale = 0.86 + 0.14 * alpha
            artwork.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateArtworks()
        let width = max(1.0, scrollView.bounds.width)
        let page = max(0, min(self.pages.count - 1, Int((scrollView.contentOffset.x / width).rounded())))
        if page != self.currentPage {
            self.artworks[self.currentPage].stop()
            self.currentPage = page
            self.pageControl.currentPage = page
            self.artworks[page].play()
        }
    }

    @objc private func alternativeLanguagePressed() {
        if let code = self.alternativeLanguageCode, !code.isEmpty {
            self.startMessagingInAlternativeLanguage?(code)
        }
    }
}

private final class AgentgramIntroView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        self.onLayout?()
    }
}

private final class AgentgramIntroPageView: UIView {
    let titleLabel = UILabel()
    let textLabel = UILabel()

    init(title: String, text: String, color: UIColor) {
        super.init(frame: CGRect())
        let isPad = UIDevice.current.userInterfaceIdiom == .pad

        self.titleLabel.font = UIFont.boldSystemFont(ofSize: 35.0)
        self.titleLabel.text = title
        self.titleLabel.textColor = color
        self.titleLabel.textAlignment = .center
        self.titleLabel.adjustsFontSizeToFitWidth = true
        self.titleLabel.minimumScaleFactor = 0.7
        self.addSubview(self.titleLabel)

        // **bold** parts, as in Telegram's texts
        let style = NSMutableParagraphStyle()
        style.lineSpacing = isPad ? 4.0 : 3.0
        style.alignment = .center
        let font = UIFont.systemFont(ofSize: isPad ? 22.0 : 17.0)
        let boldFont = UIFont.boldSystemFont(ofSize: isPad ? 22.0 : 17.0)
        let string = NSMutableAttributedString()
        for (index, part) in text.components(separatedBy: "**").enumerated() {
            string.append(NSAttributedString(string: part, attributes: [.font: index % 2 == 1 ? boldFont : font, .foregroundColor: color, .paragraphStyle: style]))
        }
        self.textLabel.attributedText = string
        self.textLabel.numberOfLines = 0
        self.addSubview(self.textLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        self.titleLabel.frame = CGRect(x: 16.0, y: 0.0, width: self.bounds.width - 32.0, height: 72.0)
        let textSize = self.textLabel.sizeThatFits(CGSize(width: self.bounds.width - 32.0, height: 200.0))
        self.textLabel.frame = CGRect(x: 16.0, y: 66.0 + (isPad ? 22.0 : 0.0), width: self.bounds.width - 32.0, height: textSize.height)
    }
}

enum AgentgramIntroTexts {
    static let russian: [(title: String, text: String)] = [
        ("Telepath", "Мессенджер, где работают\nтвои **агенты**."),
        ("Агенты", "**Claude Code**, **Codex** и другие\nотвечают в чате, как обычные\nсобеседники."),
        ("Сессии", "Каждая тема бота это **сессия**.\nВсе видны прямо в списке чатов."),
        ("Статусы", "Видно, кто из агентов **думает**,\nкто **ждёт тебя**, кто закончил."),
        ("Суперпапка", "**Работа** в своей вкладке,\n**личное** в своей."),
        ("Свой компьютер", "Агенты работают **на своём\nкомпьютере** или **своём сервере**.\nМы не видим ни сообщений, ни кода.")
    ]
    static let english: [(title: String, text: String)] = [
        ("Telepath", "The messenger where\nyour **agents** work."),
        ("Agents", "**Claude Code**, **Codex** and others\nreply in chat like\nregular people."),
        ("Sessions", "Each bot topic is a **session**.\nAll of them right in your chat list."),
        ("Statuses", "See which agent is **thinking**,\nwhich is **waiting for you**, which is done."),
        ("Superfolder", "**Work** in its own tab,\n**personal** in its own."),
        ("Your computer", "Agents run **on your computer**\nor **your own server**. We see\nneither messages nor code.")
    ]
}
