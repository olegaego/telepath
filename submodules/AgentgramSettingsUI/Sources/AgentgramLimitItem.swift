import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

// One limit window of an engine, a row of the card: the name and the percent, a bar under them (green, from 80%
// orange, at 100% red) and when it resets.

final class AgentgramLimitItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let title: String
    let percent: Double
    let reset: String
    let sectionId: ItemListSectionId

    init(presentationData: ItemListPresentationData, title: String, percent: Double, reset: String, sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.title = title
        self.percent = percent
        self.reset = reset
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AgentgramLimitItemNode()
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
            if let nodeValue = node() as? AgentgramLimitItemNode {
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

final class AgentgramLimitItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let maskNode: ASImageNode
    private let separatorNode: ASDisplayNode
    private let titleNode: TextNode
    private let percentNode: TextNode
    private let resetNode: TextNode
    private let trackNode: ASDisplayNode
    private let fillNode: ASDisplayNode

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false
        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true
        self.titleNode = TextNode()
        self.percentNode = TextNode()
        self.resetNode = TextNode()
        self.trackNode = ASDisplayNode()
        self.trackNode.isLayerBacked = true
        self.trackNode.cornerRadius = 3.0
        self.fillNode = ASDisplayNode()
        self.fillNode.isLayerBacked = true
        self.fillNode.cornerRadius = 3.0

        super.init(layerBacked: false)

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.maskNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.percentNode)
        self.addSubnode(self.trackNode)
        self.addSubnode(self.fillNode)
        self.addSubnode(self.resetNode)
    }

    func asyncLayout() -> (_ item: AgentgramLimitItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTitle = TextNode.asyncLayout(self.titleNode)
        let makePercent = TextNode.asyncLayout(self.percentNode)
        let makeReset = TextNode.asyncLayout(self.resetNode)

        return { [weak self] item, params, neighbors in
            let theme = item.presentationData.theme
            let leftInset = 16.0 + params.leftInset
            let rightInset = 16.0 + params.rightInset
            let width = params.width - leftInset - rightInset
            let font = Font.regular(item.presentationData.fontSize.itemListBaseFontSize)
            let (titleLayout, titleApply) = makeTitle(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: font, textColor: theme.list.itemPrimaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: width - 60.0, height: .greatestFiniteMagnitude)))
            let (percentLayout, percentApply) = makePercent(TextNodeLayoutArguments(attributedString: NSAttributedString(string: "\(Int(item.percent.rounded()))%", font: font, textColor: theme.list.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 80.0, height: .greatestFiniteMagnitude)))
            let (resetLayout, resetApply) = makeReset(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.reset, font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: width, height: .greatestFiniteMagnitude)))

            let height = 11.0 + titleLayout.size.height + 8.0 + 6.0 + (item.reset.isEmpty ? 0.0 : 6.0 + resetLayout.size.height) + 11.0
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: insets)
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                let _ = titleApply()
                let _ = percentApply()
                let _ = resetApply()
                let separatorHeight = UIScreenPixel

                self.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
                self.separatorNode.backgroundColor = theme.list.itemBlocksSeparatorColor
                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTop = false
                var hasBottom = false
                if case .sameSection(false) = neighbors.top {
                } else {
                    hasTop = true
                }
                switch neighbors.bottom {
                case .sameSection(false):
                    self.separatorNode.isHidden = false
                default:
                    hasBottom = true
                    self.separatorNode.isHidden = true
                }
                self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTop, bottom: hasBottom, glass: true) : nil
                self.backgroundNode.frame = CGRect(x: 0.0, y: -min(insets.top, separatorHeight), width: params.width, height: height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight))
                self.maskNode.frame = self.backgroundNode.frame.inset(by: UIEdgeInsets(top: 0.0, left: params.leftInset, bottom: 0.0, right: params.rightInset))
                self.separatorNode.frame = CGRect(x: leftInset, y: height - separatorHeight, width: params.width - leftInset - params.rightInset, height: separatorHeight)

                var y = 11.0
                self.titleNode.frame = CGRect(origin: CGPoint(x: leftInset, y: y), size: titleLayout.size)
                self.percentNode.frame = CGRect(origin: CGPoint(x: params.width - rightInset - percentLayout.size.width, y: y), size: percentLayout.size)
                y += titleLayout.size.height + 8.0
                self.trackNode.backgroundColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.18)
                self.trackNode.frame = CGRect(x: leftInset, y: y, width: width, height: 6.0)
                let color: UIColor = item.percent >= 100.0 ? UIColor(rgb: 0xFF3B30) : (item.percent >= 80.0 ? UIColor(rgb: 0xFF9500) : UIColor(rgb: 0x34C759))
                self.fillNode.backgroundColor = color
                self.fillNode.frame = CGRect(x: leftInset, y: y, width: max(6.0, width * CGFloat(min(item.percent, 100.0) / 100.0)), height: 6.0)
                y += 6.0 + 6.0
                self.resetNode.frame = CGRect(origin: CGPoint(x: leftInset, y: y), size: resetLayout.size)
            })
        }
    }
}
