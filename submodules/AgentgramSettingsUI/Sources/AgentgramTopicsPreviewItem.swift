import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

// «Topics View»: an example of the chat list under the choice. Sessions under the bot: the bot and its topics right
// under it, each with its status; Telegram's own topics: one row for the bot.

final class AgentgramTopicsPreviewItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let sessions: Bool
    let customRows: [PreviewRow]?
    let ru: Bool
    let sectionId: ItemListSectionId

    // other screens give their own rows (the statuses' examples)
    init(presentationData: ItemListPresentationData, rows: [PreviewRow], sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.sessions = true
        self.ru = true
        self.customRows = rows
        self.sectionId = sectionId
    }

    init(presentationData: ItemListPresentationData, sessions: Bool, ru: Bool, sectionId: ItemListSectionId) {
        self.customRows = nil
        self.presentationData = presentationData
        self.sessions = sessions
        self.ru = ru
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AgentgramTopicsPreviewItemNode()
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
            if let nodeValue = node() as? AgentgramTopicsPreviewItemNode {
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
}

struct PreviewRow {
    let title: String
    let text: String
    let color: UIColor
    let letter: String
    let topic: Bool
    let status: Bool
}

private let rowHeight: CGFloat = 62.0

private func renderPreview(width: CGFloat, rows: [PreviewRow], theme: PresentationTheme) -> UIImage {
    let size = CGSize(width: width, height: CGFloat(rows.count) * rowHeight)
    return UIGraphicsImageRenderer(size: size).image { _ in
        for (i, row) in rows.enumerated() {
            let top = CGFloat(i) * rowHeight
            let left: CGFloat = row.topic ? 40.0 : 14.0
            let avatar: CGFloat = row.topic ? 30.0 : 44.0
            let circle = CGRect(x: left, y: top + (rowHeight - avatar) / 2.0, width: avatar, height: avatar)
            row.color.setFill()
            UIBezierPath(ovalIn: circle).fill()
            let letterFont = UIFont.systemFont(ofSize: row.topic ? 14.0 : 19.0, weight: .semibold)
            let letter = NSAttributedString(string: row.letter, attributes: [.font: letterFont, .foregroundColor: UIColor.white])
            let letterSize = letter.size()
            letter.draw(at: CGPoint(x: circle.midX - letterSize.width / 2.0, y: circle.midY - letterSize.height / 2.0))
            if row.status {
                // the yellow dot: the session is working now
                let dot = CGRect(x: circle.maxX - 10.0, y: circle.maxY - 10.0, width: 12.0, height: 12.0)
                theme.list.itemBlocksBackgroundColor.setFill()
                UIBezierPath(ovalIn: dot.insetBy(dx: -2.0, dy: -2.0)).fill()
                UIColor(rgb: 0xF5B70A).setFill()
                UIBezierPath(ovalIn: dot).fill()
            }
            let textLeft = circle.maxX + 12.0
            let title = NSAttributedString(string: row.title, attributes: [.font: UIFont.systemFont(ofSize: 16.0, weight: .semibold), .foregroundColor: theme.list.itemPrimaryTextColor])
            title.draw(at: CGPoint(x: textLeft, y: top + 11.0))
            let text = NSAttributedString(string: row.text, attributes: [.font: UIFont.systemFont(ofSize: 14.0), .foregroundColor: theme.list.itemSecondaryTextColor])
            text.draw(at: CGPoint(x: textLeft, y: top + 33.0))
            if i < rows.count - 1 {
                theme.list.itemBlocksSeparatorColor.setFill()
                UIRectFill(CGRect(x: textLeft, y: top + rowHeight - UIScreenPixel, width: width - textLeft, height: UIScreenPixel))
            }
        }
    }
}

final class AgentgramTopicsPreviewItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let maskNode: ASImageNode
    private let imageNode: ASImageNode

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false
        self.imageNode = ASImageNode()
        self.imageNode.isLayerBacked = true
        self.imageNode.displaysAsynchronously = false

        super.init(layerBacked: false)

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.imageNode)
        self.addSubnode(self.maskNode)
    }

    func asyncLayout() -> (_ item: AgentgramTopicsPreviewItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params, neighbors in
            let ru = item.ru
            let bot = PreviewRow(title: "Claude Worker", text: item.sessions ? (ru ? "бот · 3 сессии" : "bot · 3 sessions") : (ru ? "Иконка: Вариант А готов" : "Icon: Option A is ready"), color: UIColor(rgb: 0x5856D6), letter: "C", topic: false, status: false)
            var rows = [bot]
            if let customRows = item.customRows {
                rows = customRows
            }
            if item.sessions && item.customRows == nil {
                rows.append(PreviewRow(title: ru ? "Сборка iOS" : "iOS Build", text: ru ? "запускает команду · 2 мин" : "running a command · 2 min", color: UIColor(rgb: 0xFF9500), letter: "#", topic: true, status: true))
                rows.append(PreviewRow(title: ru ? "Иконка" : "Icon", text: ru ? "Вариант А готов" : "Option A is ready", color: UIColor(rgb: 0xAF52DE), letter: "#", topic: true, status: false))
            }
            let height = CGFloat(rows.count) * rowHeight
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: insets)
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                let theme = item.presentationData.theme
                let separatorHeight = UIScreenPixel
                self.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
                self.maskNode.image = itemListHasRoundedBlockLayout(params) ? PresentationResourcesItemList.cornersImage(theme, top: true, bottom: true, glass: true) : nil
                self.backgroundNode.frame = CGRect(x: 0.0, y: -min(insets.top, separatorHeight), width: params.width, height: height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight))
                self.maskNode.frame = self.backgroundNode.frame.inset(by: UIEdgeInsets(top: 0.0, left: params.leftInset, bottom: 0.0, right: params.rightInset))
                let width = params.width - params.leftInset - params.rightInset
                self.imageNode.image = renderPreview(width: width, rows: rows, theme: theme)
                self.imageNode.frame = CGRect(x: params.leftInset, y: 0.0, width: width, height: height)
            })
        }
    }
}
