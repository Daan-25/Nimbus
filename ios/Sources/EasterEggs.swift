import CoreMotion
import SpriteKit
import SwiftUI
import UIKit

// MARK: The planet

/// Behind seven taps on Version: Nimbus's planet, big, to spin with a finger. Spin it hard
/// enough and it flies off, and comes back.
struct PlanetEgg: View {
    @Environment(\.dismiss) private var dismiss
    @State private var angle = Angle.zero
    @State private var dragStart: Angle?
    @State private var lastAngle = Angle.zero
    @State private var offset = CGSize.zero
    @State private var flights = 0

    private static let planet = renderPlanet(size: 600)

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: Self.planet)
                    .resizable()
                    .frame(width: 280, height: 280)
                    .rotationEffect(angle)
                    .offset(offset)
                    .gesture(spin(around: center))
                VStack(spacing: 6) {
                    Spacer()
                    Text("You found the planet.")
                        .font(.headline)
                    Text("Give it a spin.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)
            }
            .overlay(alignment: .topTrailing) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .padding()
            }
        }
        .foregroundStyle(.white)
        .sensoryFeedback(.impact(weight: .heavy), trigger: flights)
    }

    private func direction(of point: CGPoint, from center: CGPoint) -> Angle {
        .radians(atan2(point.y - center.y, point.x - center.x))
    }

    private func spin(around center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let now = direction(of: drag.location, from: center)
                if dragStart == nil {
                    dragStart = now
                    lastAngle = angle
                }
                angle = lastAngle + (now - (dragStart ?? now))
            }
            .onEnded { drag in
                let now = direction(of: drag.location, from: center)
                var flick = (direction(of: drag.predictedEndLocation, from: center) - now).radians
                // atan2 jumps at ±π; take the short way round.
                if flick > .pi { flick -= 2 * .pi }
                if flick < -.pi { flick += 2 * .pi }
                dragStart = nil
                let speed = abs(drag.predictedEndLocation.x - drag.location.x) + abs(drag.predictedEndLocation.y - drag.location.y)
                if speed > 900 {
                    flyAway(spin: flick)
                } else {
                    withAnimation(.timingCurve(0.1, 0.8, 0.3, 1, duration: 1.8)) {
                        angle += .radians(flick * 4)
                    }
                }
            }
    }

    /// Off the top of the screen, spinning, and back up from the bottom.
    private func flyAway(spin: Double) {
        flights += 1
        withAnimation(.easeIn(duration: 0.35)) {
            offset = CGSize(width: 0, height: -1200)
            angle += .radians(spin * 6 + (spin < 0 ? -6 : 6))
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            offset = CGSize(width: 0, height: 1200)
            withAnimation(.spring(duration: 1.1, bounce: 0.35)) {
                offset = .zero
            }
        }
    }

    private static func renderPlanet(size: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { renderer in
            let context = renderer.cgContext
            // Core Graphics draws upwards; UIKit downwards. Flip, so it looks like the icon.
            context.translateBy(x: 0, y: size)
            context.scaleBy(x: 1, y: -1)
            NimbusIcon.drawPlanet(
                in: context,
                rect: CGRect(x: 0, y: 0, width: size, height: size),
                planet: UIColor(red: 0.93, green: 0.94, blue: 1, alpha: 1).cgColor,
                ring: UIColor(red: 0.62, green: 0.68, blue: 1, alpha: 1).cgColor
            )
        }
    }
}

// MARK: Falling icons

/// Shaking the device on the Apps tab lets the app icons fall out of their rows and tumble
/// to the bottom of the screen. Tilting moves them; shaking again puts them back.
@MainActor @Observable
final class FallingIcons {
    static let shared = FallingIcons()

    private(set) var isFalling = false
    /// Where each icon was on screen, by bundle ID, so they fall from their own spot. Not
    /// observed: it changes as the list scrolls.
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored private(set) var scene: FallingScene?

    func toggle(icons: [String: UIImage]) {
        if isFalling {
            scene?.stop()
            scene = nil
            isFalling = false
            return
        }
        let screen = UIScreen.main.bounds.size
        let scene = FallingScene(size: screen)
        for (bundleID, image) in icons {
            let frame = frames[bundleID] ?? CGRect(x: screen.width / 2 - 22, y: 120, width: 44, height: 44)
            scene.add(image, at: frame)
        }
        self.scene = scene
        isFalling = true
    }
}

/// The physics of the falling icons: gravity follows how the device is held.
final class FallingScene: SKScene {
    private let motion = CMMotionManager()

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        physicsBody = SKPhysicsBody(edgeLoopFrom: CGRect(origin: .zero, size: size))
        physicsWorld.gravity = CGVector(dx: 0, dy: -9.8)
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1 / 60
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let gravity = data?.gravity else { return }
                self?.physicsWorld.gravity = CGVector(dx: gravity.x * 9.8, dy: gravity.y * 9.8)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Adds an icon where it was on screen; UIKit's y runs down, SpriteKit's up.
    func add(_ image: UIImage, at frame: CGRect) {
        let node = SKSpriteNode(texture: SKTexture(image: image), size: frame.size)
        node.position = CGPoint(x: frame.midX, y: size.height - frame.midY)
        let body = SKPhysicsBody(rectangleOf: frame.size)
        body.restitution = 0.45
        body.friction = 0.4
        body.angularDamping = 0.3
        // A little push, so they don't all drop the same way.
        body.angularVelocity = CGFloat.random(in: -2...2)
        node.physicsBody = body
        addChild(node)
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    // Flick an icon with a finger.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let now = touch.location(in: self)
            let before = touch.previousLocation(in: self)
            for node in nodes(at: now) {
                node.physicsBody?.velocity = CGVector(dx: (now.x - before.x) * 30, dy: (now.y - before.y) * 30)
            }
        }
    }
}

/// The icons rounded as on the home screen, for the falling ones.
@MainActor func roundedIcon(_ image: UIImage, size: CGFloat) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
        UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerRadius: size * 0.225).addClip()
        image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
    }
}

// MARK: Shaking

extension Notification.Name {
    static let deviceDidShake = Notification.Name("NimbusDeviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
