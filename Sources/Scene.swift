import Foundation
import simd

struct SceneControl {
    let title: String
    let range: ClosedRange<Float>
    let initial: Float
    var isIntegral = false
}

enum Scene: Int, CaseIterable {
    // Preserve the original IDs stored in UserDefaults.
    case liquid, ink, particles, glass
    case ferrofluid, ocean, blackHole, aurora, terrain, membranes, crystals, patterns
    case spectral, fluidTank, combustion, stormPlanet, fractal
    case holographic, reef, river, koi, portal, cove, batman
    case paperCity, glassBlocks, blockGlass, resonantGarden, turbine, paperFolders
    case nativeGlass

    // Keep shader and saved-preference IDs stable while excluding
    // the three reference-art scenes from every build.
    static let allCases: [Scene] = (0...Scene.nativeGlass.rawValue).compactMap(Scene.init(rawValue:))
        .filter { ![Scene.batman, .paperCity, .glassBlocks].contains($0) }

    var isAvailable: Bool { Self.allCases.contains(self) }

    var key: String {
        ["liquid", "ink", "particles", "glass", "ferrofluid", "ocean",
         "black-hole", "aurora", "terrain", "membranes", "crystals", "patterns",
         "spectral", "fluid-tank", "fire-smoke", "storm-planet", "fractal", "holographic", "reef", "river", "koi", "portal", "cove", "batman", "paper-city", "glass-blocks", "block-glass", "river-garden", "turbine", "paper-folders", "native-glass"][rawValue]
    }
    var title: String {
        ["Liquid", "Ink", "Particles", "Glass", "Ferrofluid", "Ocean & Caustics",
         "Black Hole", "Aurora", "Living Terrain", "Iridescent Membranes",
         "Crystal Growth", "Living Patterns", "Spectral Light Lab", "3D Fluid Tank",
         "Fire & Smoke", "Storm Planet", "Fractal Cathedral", "Holographic Card", "Bioluminescent Reef", "Bioluminescent River", "Koi Turntable", "Ink Portal", "Sakura Cove", "Batman: Living Ink", "Paper Metropolis", "Rippled Glass", "Glass Blocks", "River Garden", "Prismatic Turbine", "Paper Reverie", "Liquid Glass Lab"][rawValue]
    }
    var presets: [String] {
        switch self {
        case .liquid: return ["Chrome", "Black mercury", "Iridescent"]
        case .ink: return ["Ember & tide", "Aurora", "Pearl"]
        case .particles: return ["Spiral galaxy", "Nebula", "Starlight"]
        case .glass: return ["Glacier", "Amber", "Prism"]
        case .ferrofluid: return ["Obsidian", "Titanium", "Copper"]
        case .ocean: return ["Turquoise lagoon", "Midnight pool", "Golden shallows"]
        case .blackHole: return ["Event horizon", "Blue quasar", "Binary light"]
        case .aurora: return ["Borealis", "Violet storm", "Solar dawn"]
        case .terrain: return ["Alpine watershed", "Red canyon", "Volcanic island"]
        case .membranes: return ["Soap film", "Pearlescent", "Prismatic"]
        case .crystals: return ["Snowflake", "Amethyst", "Copper dendrite"]
        case .patterns: return ["Coral", "Fingerprint", "Cell division"]
        case .spectral: return ["Prism studio", "Diamond chamber", "Chromatic glass"]
        case .fluidTank: return ["Water", "Golden syrup", "Liquid metal"]
        case .combustion: return ["Fire column", "Smoke plume", "Fireball"]
        case .stormPlanet: return ["Blue marble", "Tempest", "Ember world"]
        case .fractal: return ["Gilded cathedral", "Alien reliquary", "Obsidian vault"]
        case .holographic: return ["Obsidian", "Moonstone", "Aureate"]
        case .reef: return ["Sunlit sanctuary", "Midnight bloom", "Violet lagoon"]
        case .river: return ["Moonlit cyan", "Emerald current", "Violet dusk"]
        case .koi: return ["Lagoon vinyl", "Jade garden", "Midnight pressing"]
        case .portal: return ["Vermilion", "Electric blue", "Acid sunset"]
        case .cove: return ["Golden hour", "Lantern night", "Clear morning"]
        case .batman: return ["Original artwork", "Blue hour", "Warm paper"]
        case .paperCity: return ["Original ink", "Blue dusk", "Sepia atlas"]
        case .glassBlocks: return ["Original glass", "Cool daylight", "Amber light"]
        case .blockGlass: return ["Hand-poured", "Clear blocks", "Frosted"]
        case .resonantGarden: return ["Morning dew", "Moon garden", "Golden hour"]
        case .turbine: return ["Prismatic wake", "Glacial flow", "Ember vortices"]
        case .paperFolders: return ["Pastel archive", "Botanical paper", "Lavender dusk"]
        case .nativeGlass: return ["Misty lake", "Rolling hills", "Quiet coast"]
        }
    }
    var hint: String {
        switch self {
        case .liquid: return "Move to shape · Hold to pull"
        case .ink: return "Drag to paint the flow"
        case .particles: return "Hold to attract the stars"
        case .glass: return "Move to orbit the light"
        case .ferrofluid: return "Move the magnet · Hold to lift the spikes"
        case .ocean: return "Drag to stir the water · Click to make ripples"
        case .blackHole: return "Move to orbit · Hold to warp the star field"
        case .aurora: return "Move to bend the curtains · Hold to energize"
        case .terrain: return "Drag to raise mountains · Tune rain to carve channels"
        case .membranes: return "Move to stretch · Hold to inflate the film"
        case .crystals: return "Hold to plant crystal seeds · Watch the branches grow"
        case .patterns: return "Drag to seed patterns · Tune feed and loss to transform them"
        case .spectral: return "Drag to move glass · Shift-drag light · Option-drag metal · Right-drag orbit · Scroll zoom"
        case .fluidTank: return "Hold to pour · Shift-drag the obstacle · Right-drag orbit · Scroll zoom"
        case .combustion: return "Hold to ignite · Shift-drag the obstacle · Right-drag orbit · Scroll zoom"
        case .stormPlanet: return "Drag the sun · Right-drag orbit · Scroll from space into the atmosphere"
        case .fractal: return "Right-drag to look · W A S D / Q E to fly · Scroll to travel · Drag to morph"
        case .holographic: return "Drag to tilt · Shift-drag light · Double-click to flip · Scroll to inspect"
        case .reef: return "Drag to stir currents · Right-drag to explore · Scroll to swim closer"
        case .river: return "Drag to paint luminous wakes · Click for ripples · Right-drag to explore · Scroll to approach"
        case .koi: return "Drag the record · Shift-drag to stir · Move the tonearm · Drop a music file"
        case .portal: return "Drag to bend the ink · Right-drag to orbit · Scroll to travel through the arch"
        case .batman: return "Drag the cape · Right-drag for depth · Scroll to inspect"
        case .cove: return "W A S D walk · Shift run · E interact · C free camera · R / F fly · Right-drag look · Scroll zoom"
        case .paperCity: return "Drag to lift the paper city · Right-drag for depth · Scroll to inspect"
        case .glassBlocks: return "Drag a pane to make ripples · Right-drag to shift the view · Scroll to inspect"
        case .blockGlass: return "Drop an image · Drag the glass · Right-drag to shift the view · Scroll to inspect"
        case .resonantGarden: return "Play the stones · Brush the plants · Trace the stream"
        case .turbine: return "Drag to stir the wake · Shift-hold to brake · Right-drag to orbit · Scroll to inspect"
        case .paperFolders: return "Click a folder to open · Drag to flex · Click again to settle · Right-drag to orbit · Scroll to inspect"
        case .nativeGlass: return "Drag the center to move · Hover the rim, then pull along the arrow to tear · Double-click for controls"
        }
    }
    var primaryTitle: String {
        switch self {
        case .ferrofluid: return "Magnet"
        case .ocean: return "Wind"
        case .blackHole: return "Gravity"
        case .aurora: return "Activity"
        case .terrain: return "Rain"
        case .membranes: return "Thickness"
        case .crystals: return "Growth"
        case .patterns: return "Reaction"
        case .spectral: return "Light"
        case .fluidTank: return "Pour rate"
        case .combustion: return "Fuel"
        case .stormPlanet: return "Storms"
        case .fractal: return "Complexity"
        case .holographic: return "Foil"
        case .reef, .river: return "Glow"
        case .koi: return "Ripples"
        case .portal: return "Ink"
        case .cove: return "Waves"
        case .batman: return "Cape wind"
        case .paperCity: return "Depth"
        case .glassBlocks: return "Distortion"
        case .blockGlass: return "Refraction"
        case .resonantGarden: return "Ripples"
        case .turbine: return "Wind"
        case .paperFolders: return "Spread"
        case .nativeGlass: return "Fusion"
        default: return "Intensity"
        }
    }
    var controls: [SceneControl] {
        switch self {
        case .ferrofluid:
            return [.init(title: "Surface tension", range: 0...1, initial: 0.45),
                    .init(title: "Viscosity", range: 0.1...2, initial: 0.8),
                    .init(title: "Spike spacing", range: 0.6...1.6, initial: 1)]
        case .ocean:
            return [.init(title: "Water depth", range: 0.1...1.5, initial: 0.65),
                    .init(title: "Sun angle", range: 0...1, initial: 0.65),
                    .init(title: "Choppiness", range: 0...1, initial: 0.5)]
        case .blackHole:
            return [.init(title: "Disk speed", range: 0.1...2, initial: 0.7),
                    .init(title: "Viewing angle", range: 0.12...1.1, initial: 0.28),
                    .init(title: "Disk temperature", range: 0.1...1, initial: 0.6)]
        case .aurora:
            return [.init(title: "Turbulence", range: 0.1...1.5, initial: 0.7),
                    .init(title: "Curtain height", range: 0.3...1.4, initial: 0.9),
                    .init(title: "Color shift", range: 0...1, initial: 0)]
        case .terrain:
            return [.init(title: "Sea level", range: 0.08...0.65, initial: 0.26),
                    .init(title: "Erosion", range: 0...1, initial: 0.55),
                    .init(title: "Mountain height", range: 0.5...1.6, initial: 1)]
        case .membranes:
            return [.init(title: "Tension", range: 0.05...1, initial: 0.55),
                    .init(title: "Inflation", range: 0.2...1.3, initial: 0.7),
                    .init(title: "Color shift", range: 0...1, initial: 0)]
        case .crystals:
            return [.init(title: "Branching", range: 0.1...1, initial: 0.65),
                    .init(title: "Symmetry", range: 3...8, initial: 6, isIntegral: true),
                    .init(title: "Light angle", range: 0...1, initial: 0.35)]
        case .patterns:
            return [.init(title: "Feed", range: 0.015...0.065, initial: 0.036),
                    .init(title: "Loss", range: 0.045...0.07, initial: 0.062),
                    .init(title: "Relief", range: 0.1...2, initial: 1)]
        case .spectral:
            return [.init(title: "Dispersion", range: 0...2, initial: 1),
                    .init(title: "Light size", range: 0.04...0.6, initial: 0.18),
                    .init(title: "Surface roughness", range: 0...0.35, initial: 0.035)]
        case .fluidTank:
            return [.init(title: "Viscosity", range: 0...1, initial: 0.12),
                    .init(title: "Gravity", range: 0.3...2, initial: 1),
                    .init(title: "Obstacle size", range: 0.12...0.4, initial: 0.24)]
        case .combustion:
            return [.init(title: "Vorticity", range: 0...2, initial: 0.9),
                    .init(title: "Smoke density", range: 0.2...2, initial: 0.8),
                    .init(title: "Buoyancy", range: 0.2...2, initial: 1)]
        case .stormPlanet:
            return [.init(title: "Cloud coverage", range: 0.15...1, initial: 0.50),
                    .init(title: "Sun elevation", range: -0.4...1, initial: 0.5),
                    .init(title: "Atmosphere", range: 0.2...2, initial: 1)]
        case .fractal:
            return [.init(title: "Morph", range: 0...1, initial: 0.3),
                    .init(title: "Reflection", range: 0...1, initial: 0.48),
                    .init(title: "Mist", range: 0...1, initial: 0.25)]
        case .holographic:
            return [.init(title: "Relief", range: 0...1, initial: 0.55),
                    .init(title: "Iridescence", range: 0...1.5, initial: 0.85),
                    .init(title: "Light angle", range: -1.5...1.5, initial: -0.45)]
        case .reef:
            return [.init(title: "Current", range: 0...2, initial: 0.65),
                    .init(title: "Schooling", range: 0...1, initial: 0.72),
                    .init(title: "Sunlight", range: 0...1.5, initial: 0.8)]
        case .river:
            return [.init(title: "Flow", range: 0.15...2, initial: 0.8),
                    .init(title: "Ripples", range: 0.1...1.8, initial: 0.75),
                    .init(title: "Moonlight", range: 0...1.5, initial: 0.65)]
        case .koi:
            return [.init(title: "Swim speed", range: 0.3...1.8, initial: 0.85),
                    .init(title: "Schooling", range: 0...1, initial: 0.55),
                    .init(title: "Paper texture", range: 0...1, initial: 0.55)]
        case .portal:
            return [.init(title: "River flow", range: 0.1...2, initial: 0.7),
                    .init(title: "Print grain", range: 0...1, initial: 0.65),
                    .init(title: "Landscape relief", range: 0.4...1.8, initial: 1)]
        case .cove:
            return [.init(title: "Time of day", range: 0...24, initial: 17.4),
                    .init(title: "Wind", range: 0...1.8, initial: 0.55),
                    .init(title: "Tide", range: -0.25...0.35, initial: 0)]
        case .batman:
            return [.init(title: "Smoke drift", range: 0...2, initial: 0.8),
                    .init(title: "Depth", range: 0...1, initial: 0.65),
                    .init(title: "Breathing", range: 0...1.5, initial: 0.7)]
        case .paperCity:
            return [.init(title: "Traffic", range: 0...1.5, initial: 0.8),
                    .init(title: "Paper motion", range: 0...1, initial: 0.4),
                    .init(title: "Window glow", range: 0...1, initial: 0.25)]
        case .glassBlocks:
            return [.init(title: "Glass depth", range: 0...1.5, initial: 0.8),
                    .init(title: "Edge glints", range: 0...1, initial: 0.45),
                    .init(title: "Surface flow", range: 0...2, initial: 0.7)]
        case .blockGlass:
            return [.init(title: "Thickness", range: 0.1...2, initial: 0.9),
                    .init(title: "Surface ripple", range: 0...2, initial: 0.8),
                    .init(title: "Columns", range: 2...8, initial: 4, isIntegral: true)]
        case .resonantGarden:
            return [.init(title: "Resonance", range: 0...1, initial: 0.65),
                    .init(title: "Water clarity", range: 0.2...1, initial: 0.8),
                    .init(title: "Light", range: 0.25...1.5, initial: 1)]
        case .turbine:
            return [.init(title: "Rotor speed", range: 0...2, initial: 0.65),
                    .init(title: "Turbulence", range: 0...2, initial: 0.8),
                    .init(title: "Particle density", range: 0.2...2, initial: 1)]
        case .paperFolders:
            return [.init(title: "Paper breeze", range: 0...2, initial: 0.7),
                    .init(title: "Soft focus", range: 0...1.5, initial: 0.85),
                    .init(title: "Paper grain", range: 0...1.5, initial: 0.8)]
        case .nativeGlass:
            return [.init(title: "Size", range: 0.6...1.5, initial: 1),
                    .init(title: "Tint", range: 0...1, initial: 0.08),
                    .init(title: "Backdrop drift", range: 0...1.5, initial: 0)]
        default: return []
        }
    }
    var defaultParameters: SIMD4<Float> {
        var values = SIMD4<Float>(0, 0, 0, 0)
        for (index, control) in controls.enumerated() { values[index] = control.initial }
        return values
    }
    var hasSimulation: Bool {
        [.ink, .particles, .ocean, .terrain, .crystals, .patterns, .fluidTank, .combustion, .reef, .river, .koi, .portal, .cove, .batman, .paperCity, .glassBlocks, .blockGlass, .resonantGarden, .turbine, .paperFolders].contains(self)
    }
    var isCinematic: Bool { rawValue >= Scene.spectral.rawValue && self != .nativeGlass }
    var isStatic: Bool { self == .spectral || self == .holographic }
    var isImageScene: Bool { self == .batman || self == .paperCity || self == .glassBlocks || self == .blockGlass }
    var rendersDirectly: Bool { isImageScene || self == .resonantGarden || self == .turbine || self == .paperFolders || self == .nativeGlass }
}

struct Settings {
    var scene: Scene = .liquid {
        didSet {
            if scene != oldValue { sceneParameters = scene.defaultParameters; intensity = 1; preset = 0 }
        }
    }
    var preset = 0 {
        didSet { if scene == .cove { sceneParameters.x = [Float(17.4),0,9][min(2,max(0,preset))] } }
    }
    var intensity: Float = 1
    var speed: Float = 1
    var sceneParameters = SIMD4<Float>(repeating: 0)
    var quality = 1
    var fps = 60
    var paused = false
    var showStats = false
    var reduceNativeMotion = false
    var nativeBackdropStill: Bool { scene == .nativeGlass && (sceneParameters.z <= 0 || reduceNativeMotion) }
    var particleCount: Int { [100_000, 300_000, 1_000_000, 1_000_000][quality] }
    func renderSize(for size: CGSize) -> (Int, Int) {
        let factors: [CGFloat] = [0.5, 0.75, 1, 1]
        // The expensive 3D renderers have explicit pixel budgets. Cinematic
        // spends its extra budget on convergence and detail, not a Retina trap.
        let caps: [CGFloat] = scene == .river ? [800, 1280, 1920, 3024] : (scene == .cove || scene.rendersDirectly) ? [800,1152,1920,2560] : scene.isCinematic ? [800, 1152, 1536, 1920] : [1100, 1600, 2300, 2300]
        let width = max(size.width, 1), height = max(size.height, 1)
        let scale = min(factors[quality], caps[quality] / max(width, height))
        return (max(1, Int(width * scale)), max(1, Int(height * scale)))
    }
}
