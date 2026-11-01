import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AppBundle
import TelegramCore
import AccountContext
import AvatarNode

// The top of the computer and agent screens, as in the mockups: a big computer icon (or the bot's avatar), the name in bold, and under it a status
// with a coloured dot or a line of text. No card behind it, it sits on the list's background.

final class AgentgramComputerHeaderItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let iconColor: UIColor
    let iconSize: CGFloat
    let title: String
    let status: String?
    let statusColor: UIColor?
    let text: String?
    let context: AccountContext?
    let peer: EnginePeer?
    let image: UIImage?
    let sectionId: ItemListSectionId

    init(theme: PresentationTheme, iconColor: UIColor, iconSize: CGFloat, title: String, status: String? = nil, statusColor: UIColor? = nil, text: String? = nil, context: AccountContext? = nil, peer: EnginePeer? = nil, image: UIImage? = nil, sectionId: ItemListSectionId) {
        self.image = image
        self.context = context
        self.peer = peer
        self.theme = theme
        self.iconColor = iconColor
        self.iconSize = iconSize
        self.title = title
        self.status = status
        self.statusColor = statusColor
        self.text = text
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AgentgramComputerHeaderItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? AgentgramComputerHeaderItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply()
                        })
                    }
                }
            }
        }
    }

    let selectable = false

    // the card under the header follows it closely, the header has its own space at the bottom
    var requestsNoInset: Bool {
        return true
    }
}

private func computerIcon(size: CGFloat, color: UIColor, glyphColor: UIColor) -> UIImage? {
    return generateImage(CGSize(width: size, height: size), contextGenerator: { canvas, context in
        let bounds = CGRect(origin: CGPoint(), size: canvas)
        context.clear(bounds)
        context.addPath(UIBezierPath(roundedRect: bounds, cornerRadius: size * 0.25).cgPath)
        context.setFillColor(color.cgColor)
        context.fillPath()
        if let image = UIImage(bundleImageName: "Item List/Icons/Devices"), let mask = image.cgImage {
            let scale = size * 0.6 / max(image.size.width, image.size.height)
            let glyph = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = CGRect(origin: CGPoint(x: (size - glyph.width) / 2.0, y: (size - glyph.height) / 2.0), size: glyph)
            context.saveGState()
            context.clip(to: rect, mask: mask)
            context.setFillColor(glyphColor.cgColor)
            context.fill(rect)
            context.restoreGState()
        }
    })
}

final class AgentgramComputerHeaderItemNode: ListViewItemNode {
    private let iconNode: ASImageNode
    private let avatarNode: AvatarNode
    private let titleNode: TextNode
    private let dotNode: ASImageNode
    private let statusNode: TextNode
    private let textNode: TextNode

    init() {
        self.iconNode = ASImageNode()
        self.iconNode.isLayerBacked = true
        self.iconNode.displaysAsynchronously = false
        self.avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 28.0))
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.dotNode = ASImageNode()
        self.dotNode.isLayerBacked = true
        self.dotNode.displaysAsynchronously = false
        self.statusNode = TextNode()
        self.statusNode.isUserInteractionEnabled = false
        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false

        super.init(layerBacked: false)

        self.addSubnode(self.iconNode)
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.dotNode)
        self.addSubnode(self.statusNode)
        self.addSubnode(self.textNode)
    }

    func asyncLayout() -> (_ item: AgentgramComputerHeaderItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTitle = TextNode.asyncLayout(self.titleNode)
        let makeStatus = TextNode.asyncLayout(self.statusNode)
        let makeText = TextNode.asyncLayout(self.textNode)

        return { [weak self] item, params, neighbors in
            let width = params.width - params.leftInset - params.rightInset - 40.0
            let (titleLayout, titleApply) = makeTitle(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: Font.semibold(20.0), textColor: item.theme.list.itemPrimaryTextColor), maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: width, height: .greatestFiniteMagnitude), alignment: .center))
            let (statusLayout, statusApply) = makeStatus(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.status ?? "", font: Font.regular(14.0), textColor: item.theme.list.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: width - 14.0, height: .greatestFiniteMagnitude)))
            let (textLayout, textApply) = makeText(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.text ?? "", font: Font.regular(15.0), textColor: item.theme.list.itemSecondaryTextColor), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: width, height: .greatestFiniteMagnitude), alignment: .center, lineSpacing: 0.12))

            // the avatar of an agent stands high, right under the navigation bar
            let top: CGFloat = item.text != nil ? 22.0 : 0.0
            var height = top + item.iconSize + 12.0 + titleLayout.size.height
            if item.status != nil {
                height += 4.0 + statusLayout.size.height
            }
            if item.text != nil {
                height += 8.0 + textLayout.size.height
            }
            height += 18.0

            var insets = itemListNeighborsGroupedInsets(neighbors, params)
            if case .none = neighbors.top {
                insets.top = 0.0
            }
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: insets)
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                let _ = titleApply()
                let _ = statusApply()
                let _ = textApply()
                let center = params.leftInset + (params.width - params.leftInset - params.rightInset) / 2.0

                let iconFrame = CGRect(x: floor(center - item.iconSize / 2.0), y: top, width: item.iconSize, height: item.iconSize)
                if let context = item.context, let peer = item.peer {
                    self.iconNode.isHidden = true
                    self.avatarNode.isHidden = false
                    self.avatarNode.frame = iconFrame
                    self.avatarNode.setPeer(context: context, theme: item.theme, peer: peer, displayDimensions: iconFrame.size)
                } else {
                    self.avatarNode.isHidden = true
                    self.iconNode.isHidden = false
                    self.iconNode.image = item.image ?? computerIcon(size: item.iconSize, color: item.iconColor, glyphColor: item.text != nil ? item.theme.list.itemSecondaryTextColor : .white)
                    self.iconNode.frame = iconFrame
                }
                var y = top + item.iconSize + 12.0
                self.titleNode.frame = CGRect(origin: CGPoint(x: floor(center - titleLayout.size.width / 2.0), y: y), size: titleLayout.size)
                y += titleLayout.size.height

                if item.status != nil {
                    y += 4.0
                    // without a dot the line is centred on its own
                    let dot: CGFloat = item.statusColor == nil ? 0.0 : 8.0
                    let gap: CGFloat = item.statusColor == nil ? 0.0 : 6.0
                    let rowWidth = dot + gap + statusLayout.size.width
                    let x = floor(center - rowWidth / 2.0)
                    self.dotNode.isHidden = item.statusColor == nil
                    if let color = item.statusColor {
                        self.dotNode.image = generateFilledCircleImage(diameter: dot, color: color)
                    }
                    self.dotNode.frame = CGRect(x: x, y: y + floor((statusLayout.size.height - dot) / 2.0), width: dot, height: dot)
                    self.statusNode.frame = CGRect(origin: CGPoint(x: x + dot + gap, y: y), size: statusLayout.size)
                    y += statusLayout.size.height
                } else {
                    self.dotNode.isHidden = true
                    self.statusNode.frame = .zero
                }

                if item.text != nil {
                    y += 8.0
                    self.textNode.frame = CGRect(origin: CGPoint(x: floor(center - textLayout.size.width / 2.0), y: y), size: textLayout.size)
                } else {
                    self.textNode.frame = .zero
                }
            })
        }
    }
}
