import AppKit
import ImageIO
import Metal
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// The app icon: a buddy that has used up its quota hands over to a wide-awake one, on a sand tile.
/// Both are the panel's buddies, their faces raised into 3D from `BuddyArt`, so the icon follows the face.
/// Every size comes from one rendering.
public enum AppIconArtwork {
    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    private static func bitmap(_ side: Int) -> CGContext? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The macOS icon outline: a superellipse (n = 5) inside the standard 824 pt tile of a 1024 canvas.
    static func tilePath() -> CGPath {
        let p = CGMutablePath(), n = 5.0, a = 412.0
        for i in 0...720 {
            let t = Double(i) / 720 * 2 * .pi, c = cos(t), s = sin(t)
            let x = 512 + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
            let y = 512 + a * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }

    // MARK: The buddies

    /// How a buddy looks in the icon: the panel's skin, deepened so it keeps its colour under the light, and its ink.
    private struct Look {
        var skin: NSColor
        var ink: NSColor
    }

    private static var awake: Look { Look(skin: color(0x8FD872), ink: color(Theme.buddyHex(.ok).ink)) }
    private static var spent: Look { Look(skin: color(0xF39C8C), ink: color(Theme.buddyHex(.low).ink)) }

    /// The line the panel draws its large buddies with.
    private static let line: CGFloat = 1.8

    /// The head's side in the design square, which is `BuddyArt.design` wide with the head inset 1.5 all round.
    private static var headSide: CGFloat { BuddyArt.design - 3 }

    /// `path` moved from the design square (y down) onto the 3D head: one unit wide, centred, y up.
    private static func onHead(_ path: Path) -> CGPath {
        let half = BuddyArt.design / 2
        var t = CGAffineTransform(a: 1 / headSide, b: 0, c: 0, d: -1 / headSide, tx: -half / headSide, ty: half / headSide)
        return path.cgPath.copy(using: &t) ?? CGMutablePath()
    }

    /// Each run of `path` that starts with a move, on its own.
    private static func pieces(_ path: CGPath) -> [CGMutablePath] {
        var runs: [CGMutablePath] = []
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                let run = CGMutablePath()
                run.move(to: p[0])
                runs.append(run)
            case .addLineToPoint: runs.last?.addLine(to: p[0])
            case .addQuadCurveToPoint: runs.last?.addQuadCurve(to: p[1], control: p[0])
            case .addCurveToPoint: runs.last?.addCurve(to: p[2], control1: p[0], control2: p[1])
            case .closeSubpath: runs.last?.closeSubpath()
            @unknown default: break
            }
        }
        return runs
    }

    private static func material(_ contents: Any, roughness: Double) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = contents
        m.roughness.contents = roughness
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.05
        return m
    }

    /// A solid standing `depth` deep on the outline of `path`, its edges rounded.
    private static func raised(_ path: CGPath, depth: CGFloat, rounding: CGFloat) -> SCNShape {
        let outline = NSBezierPath(cgPath: path)
        outline.flatness = 0.002
        let shape = SCNShape(path: outline, extrusionDepth: depth)
        shape.chamferRadius = rounding
        return shape
    }

    /// The face the panel draws for `mood`, raised off the front of the head at `front`:
    /// round eyes and glints become domes, every other mark stands up from its outline.
    private static func face(_ mood: BuddyMood, ink: NSColor, front: CGFloat) -> SCNNode {
        let node = SCNNode()
        let inkMaterial = material(ink, roughness: 0.08)
        let glint = SCNMaterial()
        glint.lightingModel = .constant
        glint.diffuse.contents = NSColor.white
        func add(_ geometry: SCNGeometry, _ m: SCNMaterial, at p: SCNVector3, squash: CGFloat = 1) {
            let part = SCNNode(geometry: geometry)
            part.geometry?.firstMaterial = m
            part.position = p
            part.scale = SCNVector3(1, 1, squash)
            node.addChildNode(part)
        }
        func fill(_ path: Path, _ m: SCNMaterial, lift: CGFloat, squash: CGFloat) {
            for piece in pieces(onHead(path)) {
                let box = piece.boundingBoxOfPath
                if abs(box.width - box.height) < 0.0001 {
                    add(SCNSphere(radius: box.width / 2), m, at: SCNVector3(box.midX, box.midY, front + lift), squash: squash)
                } else {
                    add(raised(piece, depth: 0.03, rounding: 0.006), m, at: SCNVector3(0, 0, front + lift))
                }
            }
        }
        fill(BuddyArt.eyesFilled(mood), inkMaterial, lift: 0, squash: 0.5)
        fill(BuddyArt.mouthFilled(mood), inkMaterial, lift: 0, squash: 0.5)
        fill(BuddyArt.glint(mood), glint, lift: 0.035, squash: 0.4)
        for marks in [BuddyArt.eyeLines(mood), BuddyArt.mouthLine(mood), BuddyArt.z(mood)] where !marks.isEmpty {
            let stroke = onHead(marks).copy(strokingWithWidth: line / headSide, lineCap: .round, lineJoin: .round, miterLimit: 4)
            add(raised(stroke, depth: 0.03, rounding: 0.006), inkMaterial, at: SCNVector3(0, 0, front + 0.01))
        }
        return node
    }

    /// The front of the head: the skin with the panel's cheeks on it, soft-edged.
    private static func frontTexture(_ skin: NSColor) -> CGImage? {
        let side = CGFloat(1024)
        guard let c = bitmap(Int(side)),
              let fade = CGGradient(colorsSpace: sRGB, colors: [color(PaletteHex.accentClay, 0.6).cgColor,
                                                                color(PaletteHex.accentClay, 0).cgColor] as CFArray, locations: [0, 1])
        else { return nil }
        c.setFillColor(skin.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: side, height: side))
        for cheek in pieces(BuddyArt.blush.cgPath) {
            let box = cheek.boundingBoxOfPath
            // The texture covers the head, 1.5...34.5 of the design square; its rows run up where the design runs down.
            c.saveGState()
            c.translateBy(x: (box.midX - 1.5) / headSide * side, y: (1 - (box.midY - 1.5) / headSide) * side)
            c.scaleBy(x: box.width * 0.68 / headSide * side, y: box.height * 0.72 / headSide * side)
            c.drawRadialGradient(fade, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            c.restoreGState()
        }
        return c.makeImage()
    }

    private static func buddy(_ look: Look, mood: BuddyMood) -> SCNNode {
        let root = SCNNode()
        let depth: CGFloat = 0.9
        // The head's corner as the panel draws it: 11 on a side of 33.
        let head = SCNBox(width: 1, height: 1, length: depth, chamferRadius: 11 / headSide)
        head.chamferSegmentCount = 24
        let side = material(look.skin, roughness: 0.3)
        let front = material(frontTexture(look.skin) ?? look.skin, roughness: 0.3)
        for m in [side, front] { m.emission.contents = look.skin.blended(withFraction: 0.84, of: .black) }
        head.materials = [front, side, side, side, side, side]
        root.addChildNode(SCNNode(geometry: head))
        root.addChildNode(face(mood, ink: look.ink, front: depth / 2))
        return root
    }

    /// The hand-over: an arrow that leaves the spent buddy and comes down on the awake one.
    private static func handOver() -> [SCNGeometry] {
        let start = CGPoint(x: -0.6, y: 0.5), bend = CGPoint(x: -0.08, y: 1.12), end = CGPoint(x: 0.36, y: 0.8)
        let width: CGFloat = 0.13, head: CGFloat = 0.34
        let length = hypot(end.x - bend.x, end.y - bend.y)
        let ux = (end.x - bend.x) / length, uy = (end.y - bend.y) / length
        let base = CGPoint(x: end.x - ux * head / 2, y: end.y - uy * head / 2)
        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addQuadCurve(to: base, control: bend)
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: end.x + ux * head / 2, y: end.y + uy * head / 2))
        tip.addLine(to: CGPoint(x: base.x - uy * head * 0.55, y: base.y + ux * head * 0.55))
        tip.addLine(to: CGPoint(x: base.x + uy * head * 0.55, y: base.y - ux * head * 0.55))
        tip.closeSubpath()
        return [raised(shaft.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4), depth: 0.09, rounding: 0.03),
                raised(tip, depth: 0.09, rounding: 0.03)]
    }

    // MARK: The rendering

    /// A soft studio for the reflections: sky above, a light floor below, two windows up and to the sides.
    private static func studio() -> CGImage? {
        guard let c = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sky = CGGradient(colorsSpace: sRGB, colors: [color(0xA7B0BD), color(0xFFFFFF), color(0xDCEBFF)].map(\.cgColor) as CFArray,
                                   locations: [0, 0.5, 1])
        else { return nil }
        c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
        for (rect, alpha, radius) in [(CGRect(x: 307, y: 338, width: 164, height: 102), 1.0, 30.0), (CGRect(x: 799, y: 282, width: 82, height: 72), 0.7, 20.0)] {
            c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            c.setFillColor(color(0xFFFFFF, alpha).cgColor)
            c.fillPath()
        }
        return c.makeImage()
    }

    /// The scene, `pixels` wide, on a clear background.
    private static func scene(pixels: Int) -> CGImage? {
        // Without Metal SceneKit would hand back an empty picture; better no icon than a bare tile.
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = studio()
        scene.lightingEnvironment.intensity = 1.4
        func light(_ intensity: CGFloat, _ angles: SCNVector3) {
            let light = SCNLight()
            light.type = .directional
            light.intensity = intensity
            let node = SCNNode()
            node.light = light
            node.eulerAngles = angles
            scene.rootNode.addChildNode(node)
        }
        light(900, SCNVector3(-1.15, -0.45, 0))
        light(260, SCNVector3(-0.2, 0.9, 0))
        light(700, SCNVector3(-0.6, .pi * 0.85, 0))

        let tired = buddy(spent, mood: .sleepy)
        tired.scale = SCNVector3(0.82, 0.82, 0.82)
        tired.position = SCNVector3(-0.62, -0.09, -0.35)
        tired.eulerAngles = SCNVector3(0.05, 0.32, 0.1)
        let fresh = buddy(awake, mood: .happy)
        fresh.position = SCNVector3(0.5, 0.12, 0.15)
        fresh.eulerAngles = SCNVector3(0.06, -0.38, -0.06)
        scene.rootNode.addChildNode(tired)
        scene.rootNode.addChildNode(fresh)
        for piece in handOver() {
            let node = SCNNode(geometry: piece)
            node.geometry?.firstMaterial = material(color(0xFF7A4D), roughness: 0.16)
            node.position.z = -0.05
            scene.rootNode.addChildNode(node)
        }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 20
        camera.position = SCNVector3(0, 0.55, 7.2)
        camera.look(at: SCNVector3(0, 0.3, 0))
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The whole icon at 1024: the sand tile and its light, the scene, the tile's rim.
    private static func master() -> CGImage? {
        guard let art = scene(pixels: 1024), let c = bitmap(1024),
              let sand = CGGradient(colorsSpace: sRGB, colors: [color(0xF4E7D2), color(0xE6D3B4), color(0xD4BB93)].map(\.cgColor) as CFArray, locations: nil),
              let glow = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, 0.42), color(0xFFFFFF, 0)].map(\.cgColor) as CFArray, locations: nil),
              let rim = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)].map(\.cgColor) as CFArray, locations: nil),
              let shade = CGGradient(colorsSpace: sRGB, colors: [color(0x6B4A30, 1), color(0x6B4A30, 0)].map(\.cgColor) as CFArray, locations: nil)
        else { return nil }
        // Design space: 1024 × 1024, y down.
        c.translateBy(x: 0, y: 1024); c.scaleBy(x: 1, y: -1)
        let tile = tilePath()
        c.saveGState()
        // Shadow offsets stay in the bitmap's own space, where y runs up: a negative height falls below the tile.
        c.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.26).cgColor)
        c.addPath(tile); c.setFillColor(color(0xD4BB93).cgColor); c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(tile); c.clip()
        c.drawLinearGradient(sand, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.drawRadialGradient(glow, startCenter: CGPoint(x: 350, y: 250), startRadius: 0, endCenter: CGPoint(x: 350, y: 250), endRadius: 540, options: [])
        // The buddies' shadows on the sand: the tired one sits, the awake one is in the air, so its shadow is fainter.
        for (centre, size, strength) in [(CGPoint(x: 338, y: 752), CGSize(width: 136, height: 22), 0.3),
                                         (CGPoint(x: 676, y: 772), CGSize(width: 124, height: 17), 0.17)] {
            c.saveGState()
            c.setAlpha(strength)
            c.translateBy(x: centre.x, y: centre.y); c.scaleBy(x: size.width, y: size.height)
            c.drawRadialGradient(shade, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            c.restoreGState()
        }
        c.saveGState()
        c.translateBy(x: 122, y: 896); c.scaleBy(x: 1, y: -1)
        c.draw(art, in: CGRect(x: 0, y: 0, width: 780, height: 780))
        c.restoreGState()
        c.addPath(tile); c.setLineWidth(10); c.replacePathWithStrokedPath(); c.clip()
        c.drawLinearGradient(rim, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 330), options: [])
        c.restoreGState()
        return c.makeImage()
    }

    /// `image` brought down to `pixels`, halving first so the small sizes stay crisp.
    private static func scaled(_ image: CGImage, to pixels: Int) -> CGImage? {
        var current = image
        while current.width / 2 >= pixels * 2 {
            guard let half = bitmap(current.width / 2) else { return nil }
            half.interpolationQuality = .high
            half.draw(current, in: CGRect(x: 0, y: 0, width: current.width / 2, height: current.width / 2))
            guard let next = half.makeImage() else { return nil }
            current = next
        }
        guard let c = bitmap(pixels) else { return nil }
        c.interpolationQuality = .high
        c.draw(current, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return c.makeImage()
    }

    /// One square rendering of the icon, `pixels` wide.
    public static func iconImage(pixels: Int) -> CGImage? {
        master().flatMap { scaled($0, to: pixels) }
    }

    /// The `.iconset` contents `iconutil` turns into an `.icns`: 16 to 512 pt at 1x and 2x.
    public static let iconsetFiles: [(name: String, pixels: Int)] = [16, 32, 128, 256, 512].flatMap { size in
        [("icon_\(size)x\(size).png", size), ("icon_\(size)x\(size)@2x.png", size * 2)]
    }

    public static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let master = master() else { throw CocoaError(.fileWriteUnknown) }
        for file in iconsetFiles {
            guard let image = scaled(master, to: file.pixels),
                  let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(file.name) as CFURL,
                                                                    UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
