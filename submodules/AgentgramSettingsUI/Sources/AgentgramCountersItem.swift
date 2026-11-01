import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

// A row of counters in one card, as in axagent: the limits of the engine and the turns of today. A big number, a
// caption under it, thin lines between them

struct AgentgramCounter: Equatable {
    let value: String
    let caption: String
    let color: UInt32?
}

final class AgentgramCountersItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let counters: [AgentgramCounter]
    let sectionId: ItemListSectionId

    init(presentationData: ItemListPresentationData, counters: [AgentgramCounter], sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.counters = counters
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AgentgramCountersItemNode()
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
            if let nodeValue = node() as? AgentgramCountersItemNode {
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

final class AgentgramCountersItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let maskNode: ASImageNode
    private var valueNodes: [TextNode] = []
    private var captionNodes: [TextNode] = []
    private var lineNodes: [ASDisplayNode] = []

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false
        super.init(layerBacked: false)
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.maskNode)
        for _ in 0 ..< 3 {
            let value = TextNode()
            let caption = TextNode()
            let line = ASDisplayNode()
            line.isLayerBacked = true
            self.valueNodes.append(value)
            self.captionNodes.append(caption)
            self.lineNodes.append(line)
            self.addSubnode(value)
            self.addSubnode(caption)
            self.addSubnode(line)
        }
    }

    func asyncLayout() -> (_ item: AgentgramCountersItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeValues = self.valueNodes.map { TextNode.asyncLayout($0) }
        let makeCaptions = self.captionNodes.map { TextNode.asyncLayout($0) }

        return { [weak self] item, params, neighbors in
            let theme = item.presentationData.theme
            let counters = Array(item.counters.prefix(3))
            let cellWidth = (params.width - params.leftInset - params.rightInset) / CGFloat(max(1, counters.count))
            var values: [(TextNodeLayout, () -> TextNode)] = []
            var captions: [(TextNodeLayout, () -> TextNode)] = []
            for i in 0 ..< 3 {
                let counter = i < counters.count ? counters[i] : nil
                let color = counter?.color.flatMap { UIColor(rgb: $0) } ?? theme.list.itemPrimaryTextColor
                values.append(makeValues[i](TextNodeLayoutArguments(attributedString: NSAttributedString(string: counter?.value ?? "", font: Font.semibold(item.presentationData.fontSize.itemListBaseFontSize + 1.0), textColor: color), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: cellWidth - 8.0, height: .greatestFiniteMagnitude), alignment: .center)))
                captions.append(makeCaptions[i](TextNodeLayoutArguments(attributedString: NSAttributedString(string: counter?.caption ?? "", font: Font.regular(12.0), textColor: theme.list.itemSecondaryTextColor), maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: cellWidth - 8.0, height: .greatestFiniteMagnitude), alignment: .center)))
            }
            let valueHeight = values.map { $0.0.size.height }.max() ?? 0.0
            let captionHeight = captions.map { $0.0.size.height }.max() ?? 0.0
            let height = 11.0 + valueHeight + 2.0 + captionHeight + 11.0
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: insets)
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                let separatorHeight = UIScreenPixel
                self.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTop = false
                var hasBottom = false
                if case .sameSection(false) = neighbors.top {
                } else {
                    hasTop = true
                }
                if case .sameSection(false) = neighbors.bottom {
                } else {
                    hasBottom = true
                }
                self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTop, bottom: hasBottom, glass: true) : nil
                self.backgroundNode.frame = CGRect(x: 0.0, y: -min(insets.top, separatorHeight), width: params.width, height: height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight))
                self.maskNode.frame = self.backgroundNode.frame.inset(by: UIEdgeInsets(top: 0.0, left: params.leftInset, bottom: 0.0, right: params.rightInset))
                for i in 0 ..< 3 {
                    let value = values[i].1()
                    let caption = captions[i].1()
                    let x = params.leftInset + cellWidth * CGFloat(i)
                    value.frame = CGRect(origin: CGPoint(x: x + floor((cellWidth - values[i].0.size.width) / 2.0), y: 11.0), size: values[i].0.size)
                    caption.frame = CGRect(origin: CGPoint(x: x + floor((cellWidth - captions[i].0.size.width) / 2.0), y: 11.0 + valueHeight + 2.0), size: captions[i].0.size)
                    self.lineNodes[i].backgroundColor = theme.list.itemBlocksSeparatorColor
                    self.lineNodes[i].isHidden = i == 0 || i >= counters.count
                    self.lineNodes[i].frame = CGRect(x: x, y: 10.0, width: UIScreenPixel, height: height - 20.0)
                }
            })
        }
    }
}
