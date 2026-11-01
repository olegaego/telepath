import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import SolidRoundedButtonNode

// «Принимаю» and «Не сейчас» at the very end of the first-run screen, in the list itself: to reach them one scrolls
// through everything above

final class AgentgramWelcomeButtonsItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let title: String
    let secondaryTitle: String
    let action: () -> Void
    let secondaryAction: () -> Void
    let sectionId: ItemListSectionId

    init(theme: PresentationTheme, title: String, secondaryTitle: String, action: @escaping () -> Void, secondaryAction: @escaping () -> Void, sectionId: ItemListSectionId) {
        self.theme = theme
        self.title = title
        self.secondaryTitle = secondaryTitle
        self.action = action
        self.secondaryAction = secondaryAction
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AgentgramWelcomeButtonsItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)
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
            if let nodeValue = node() as? AgentgramWelcomeButtonsItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params)
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

final class AgentgramWelcomeButtonsItemNode: ListViewItemNode {
    private var buttonNode: SolidRoundedButtonNode?
    private let secondaryButtonNode: HighlightableButtonNode
    private var item: AgentgramWelcomeButtonsItem?

    init() {
        self.secondaryButtonNode = HighlightableButtonNode()
        super.init(layerBacked: false)
        self.addSubnode(self.secondaryButtonNode)
        self.secondaryButtonNode.addTarget(self, action: #selector(self.secondaryPressed), forControlEvents: .touchUpInside)
    }

    @objc private func secondaryPressed() {
        self.item?.secondaryAction()
    }

    func asyncLayout() -> (_ item: AgentgramWelcomeButtonsItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params in
            let buttonHeight: CGFloat = 52.0
            let height = 8.0 + buttonHeight + 14.0 + 22.0 + 20.0
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                self.item = item
                let buttonTheme = SolidRoundedButtonTheme(backgroundColor: item.theme.list.itemCheckColors.fillColor, foregroundColor: item.theme.list.itemCheckColors.foregroundColor)
                let button: SolidRoundedButtonNode
                if let current = self.buttonNode {
                    button = current
                    button.updateTheme(buttonTheme, animated: false)
                } else {
                    button = SolidRoundedButtonNode(theme: buttonTheme, height: buttonHeight, cornerRadius: buttonHeight / 2.0, isShimmering: false)
                    self.buttonNode = button
                    self.addSubnode(button)
                }
                button.title = item.title
                button.pressed = { [weak self] in
                    self?.item?.action()
                }
                let inset = 16.0 + params.leftInset
                let width = params.width - inset - 16.0 - params.rightInset
                let _ = button.updateLayout(width: width, transition: .immediate)
                button.frame = CGRect(x: inset, y: 8.0, width: width, height: buttonHeight)
                self.secondaryButtonNode.setTitle(item.secondaryTitle, with: Font.regular(17.0), with: item.theme.list.itemAccentColor, for: .normal)
                self.secondaryButtonNode.frame = CGRect(x: inset, y: 8.0 + buttonHeight + 14.0, width: width, height: 22.0)
            })
        }
    }
}
