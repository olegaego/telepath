import Foundation
import UIKit
import Display
import AccountContext
import PresentationDataUtils

// The look shared by Agentgram's screens, as on the agent's screen: a big tile with the screen's sign on top,
// a coloured icon at every row, a light capsule for an action in a row.

// a coloured rounded square with a white SF symbol: 30 for a row, bigger for the top of a screen
func agentgramSymbolTile(_ name: String, _ color: UInt32, size: CGFloat = 30.0) -> UIImage? {
    return generateImage(CGSize(width: size, height: size), rotatedContext: { canvas, context in
        context.clear(CGRect(origin: CGPoint(), size: canvas))
        context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: canvas), cornerRadius: size * (size > 40.0 ? 0.226 : 0.266)).cgPath)
        context.setFillColor(UIColor(rgb: color).cgColor)
        context.fillPath()
        if let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.47, weight: .semibold))?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            UIGraphicsPushContext(context)
            symbol.draw(in: CGRect(x: (canvas.width - symbol.size.width) / 2.0, y: (canvas.height - symbol.size.height) / 2.0, width: symbol.size.width, height: symbol.size.height))
            UIGraphicsPopContext()
        }
    })
}

// the size of the tile on top of a screen
let agentgramHeroTileSize: CGFloat = 72.0

// a light capsule with the accent text, like «Open» in the App Store
func agentgramCapsule(_ text: String, color: UIColor) -> (UIImage, CGSize)? {
    let font = Font.semibold(15.0)
    let textSize = (text as NSString).size(withAttributes: [.font: font])
    let size = CGSize(width: ceil(textSize.width) + 28.0, height: 30.0)
    guard let image = generateImage(size, rotatedContext: { canvas, context in
        context.clear(CGRect(origin: CGPoint(), size: canvas))
        context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: canvas), cornerRadius: canvas.height / 2.0).cgPath)
        context.setFillColor(color.withAlphaComponent(0.14).cgColor)
        context.fillPath()
        UIGraphicsPushContext(context)
        (text as NSString).draw(at: CGPoint(x: 14.0, y: (canvas.height - textSize.height) / 2.0), withAttributes: [.font: font, .foregroundColor: color])
        UIGraphicsPopContext()
    }) else {
        return nil
    }
    return (image, size)
}

// a ring that fills as a download goes
func agentgramProgressRing(_ progress: Double, color: UIColor, track: UIColor) -> (UIImage, CGSize)? {
    let size = CGSize(width: 24.0, height: 24.0)
    guard let image = generateImage(size, rotatedContext: { canvas, context in
        context.clear(CGRect(origin: CGPoint(), size: canvas))
        let center = CGPoint(x: canvas.width / 2.0, y: canvas.height / 2.0)
        let radius = canvas.width / 2.0 - 2.0
        context.setLineWidth(3.0)
        context.setLineCap(.round)
        context.setStrokeColor(track.cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: false)
        context.strokePath()
        context.setStrokeColor(color.cgColor)
        // the context is flipped: clockwise here runs clockwise on screen from the top
        context.addArc(center: center, radius: radius, startAngle: -.pi / 2.0, endAngle: -.pi / 2.0 + .pi * 2.0 * CGFloat(max(0.02, min(1.0, progress))), clockwise: false)
        context.strokePath()
    }) else {
        return nil
    }
    return (image, size)
}

// The engines an agent can run on, by their ids from the helper; «chat» has no tools (a demo agent)
let agentgramEngines: [(id: String, name: String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("chat", "Только ответы")]

func agentgramEngineName(_ id: String?) -> String {
    return agentgramEngines.first(where: { $0.id == id })?.name ?? "Claude Code"
}

// A short message with «OK»: a computer not on this network, a request that failed
func agentgramAlert(_ context: AccountContext, _ text: String) -> ViewController {
    return textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})])
}

// Each engine's icon at its row
private let engineIcons: [String: UIImage?] = [
    "claude": agentgramSymbolTile("sparkle", 0xD97757),
    "codex": agentgramSymbolTile("terminal.fill", 0x3A3A3C),
    "chat": agentgramSymbolTile("bubble.left.fill", 0x34C759)
]

func agentgramEngineIcon(_ id: String) -> UIImage? {
    return engineIcons[id] ?? engineIcons["claude"] ?? nil
}
