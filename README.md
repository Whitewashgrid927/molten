# Molten

A native, local Metal playground for Apple silicon Macs. Version 1.18.0 includes 28 scenes, 84 looks, and compact Liquid Glass controls. No network access, telemetry, third-party runtime, privileged helper, or hardware-setting changes.

The public catalog contains 28 scenes. The three reference-art scenes are excluded in all builds, and their source images are omitted. The scene IDs are retained for shader compatibility.

## Scenes

- **Liquid:** ray-marched, smoothly merging surfaces with studio reflections. Chrome, black mercury, and iridescent looks. Move the pointer to shape the surface; hold to pull it.
- **Ink:** GPU fluid simulation with semi-Lagrangian advection, vorticity confinement, Jacobi pressure projection, and dye transport. Drag to paint.
- **Particles:** persistent GPU buffers and compute updates, followed by direct GPU color accumulation and a resolve pass. This preserves the Gaussian star shapes while avoiding the cost of drawing a million point primitives. Eco uses 100,000 particles, Balanced 300,000, and High 1,000,000. Hold to attract.
- **Glass:** actual Metal ray queries against a triangle acceleration structure, with entry and exit refraction and Fresnel reflection. This is a stylized renderer, not a full path tracer or caustics solver.
- **Ferrofluid:** reflective magnetic spikes on a deforming height field. Move the magnet, hold to lift, and tune strength, surface tension, viscosity, and spike spacing.
- **Ocean & Caustics:** a persistent damped-wave simulation, wind waves, refraction, and an animated approximation of underwater caustics. Drag to stir; tune wind, water depth, sun angle, and choppiness.
- **Black Hole:** bent rays, an emissive rotating disk, a capture region, and a lensed star field. Move to orbit; tune gravity, disk speed, viewing angle, and temperature. An artistic lensing approximation, not a general-relativity solver.
- **Aurora:** volumetric integration through folded light curtains above a dark horizon. Bend and energize them with the pointer; tune activity, turbulence, height, and color.
- **Living Terrain:** a persistent height field with rain, water flow, sediment transport, erosion, and deposition. A shaded relief-map view keeps sculpting aligned with the cursor. Tune rain, sea level, erosion, and mountain height.
- **Iridescent Membranes:** deforming thin films with wavelength-dependent interference. Stretch and inflate with the pointer; tune thickness, tension, inflation, and color.
- **Crystal Growth:** a persistent diffusion/deposition simulation with directional growth. Hold to plant seeds; tune growth, branching, symmetry, and light. Reset starts fresh after crystals fill the available space.
- **Living Patterns:** persistent Gray–Scott reaction/diffusion chemistry, with coral, fingerprint, and cell-like presets. Drag to seed; tune reaction rate, feed, loss, and surface relief.

- **Spectral Light Lab:** GPU path tracing with three wavelength bands, wavelength-dependent refraction, Fresnel reflection, up to ten ray bounces, sampled area lighting, diffuse color transfer, and a 131,072-photon caustic pass. Move the prism or gemstone by dragging; Shift-drag the light and Option-drag the metal sphere. Presets: prism studio, diamond chamber, chromatic glass.
- **3D Fluid Tank:** 16,384 GPU particle slots, a spatial neighbor grid, three density-projection iterations per 120 Hz physics tick, viscosity, gravity, tank collisions, and a floating/falling spherical obstacle. The particles reconstruct a 3D density field, rendered as a refractive surface with thickness-dependent absorption. Water, golden syrup, and liquid metal have distinct optical and viscosity settings. Hold to pour; Shift-drag the obstacle.
- **Fire & Smoke:** a 3D Eulerian simulation with advected velocity, fuel, temperature, and smoke; combustion, cooling, buoyancy, vorticity confinement, obstacle boundaries, and pressure projection. The volume renderer integrates emission, extinction, and sampled self-shadowing. Fire column, smoke plume, and periodically ignited fireball presets. Hold to ignite at the pointer; Shift-drag the obstacle.
- **Storm Planet:** a curved cloud volume over procedural oceans, land, ice, and night lights; a rotating hurricane, intermittent lightning, cloud shadows, and an integrated Rayleigh/Mie-style atmosphere. Blue marble, a dusk tempest, and an ember world. Drag to move the sun, orbit with right-drag, and scroll from space into the cloud layer.
- **Fractal Cathedral:** a repeated folded distance field with an open nave, orbit-trap materials, adaptive ray termination, ambient occlusion, soft shadows, a reflection trace, and mist. Morph the geometry by dragging or with its tuning control. Right-drag to look, W/A/S/D to fly, Q/E to rise or descend, and scroll to move forward/backward. Hold Shift while flying for a faster camera.

- **Holographic Card:** an original Obsidian collector's card, with a silver moth illustration, engraved borders and lettering, angle-dependent foil, view-dependent recessed artwork, a hidden constellation, and a separately designed reverse. Obsidian, Moonstone, and Aureate finishes. Drag to tilt; Shift-drag to position the light, double-click to flip, and scroll to inspect. Foil, relief, iridescence, and light-angle controls update immediately. Text is rasterized once into a small monochrome atlas using AppKit; the artwork and material layers are procedural Metal shaders.
- **Bioluminescent Reef:** a 3D underwater garden with 56 swaying kelp stalks and leaves, branching coral and sponge colonies, three coordinated fish schools, twelve translucent pulsing jellyfish and trailing tentacles, and advected glowing plankton. Drag to inject currents; fish avoid the disturbance, kelp and tentacles bend, and plankton retains a decaying luminous wake. Right-drag orbits the environment; scroll swims closer. Sunlit sanctuary, Midnight bloom, and Violet lagoon change the lighting and palette. Tune glow, current, schooling, and sunlight.
- **Bioluminescent River:** a detailed forest river at night, with branching trees, exposed roots, individual leaves and ferns, a fallen trunk, wet irregular stones, fireflies, and drifting mist. Metal ray tracing renders the forest, shadows, water reflections, and the submerged riverbed. Persistent organisms flare in disturbed water and produce small spray particles. Click for ripples or drag to stir glowing wakes that travel downstream and fade. Right-drag explores the scene; scroll approaches the water. Moonlit cyan, Emerald current, and Violet dusk provide three palettes. Tune glow, flow, ripples, and moonlight.

- **Koi Turntable:** a turquoise record pond on textured paper, seven independently swimming koi, translucent fins, a rotating veined lily-pad label, fine vinyl grooves, and persistent wakes. Drag the record forward or backward and release to coast; Shift-drag stirs without grabbing the platter. The left fader controls the motor, its round button toggles the motor, and the tonearm can be lifted to its rest. Lagoon vinyl, Jade garden, and Midnight pressing offer three palettes. Tune ripples, swim speed, schooling, and paper texture.
- **Ink Portal:** an extruded arch, eroded terrain, a banded flowing river, and floating moons rendered with a limited screen-print palette. Right-drag reveals the geometry; scroll forward through the arch to another palette and space. Drag to perturb the ink. Vermilion, Electric blue, and Acid sunset are the three initial looks. Tune ink, river flow, print grain, and landscape relief.

**Sakura Cove:** a playable seaside terrace with a hat-wearing character, individual paving stones, weathered blue plaster, a slatted bench, a swinging lantern, a branching cherry tree, falling petals, tidal rocks, and transparent ocean water. Walk with W/A/S/D, hold Shift to run, and press E near the bench to sit or stand. E near the lantern or clicking the lantern gives it a push. C switches to a free camera; W/A/S/D moves, R/F rises/descends, and C returns to the character. Right-drag orbits/looks and scroll adjusts orbit distance. Click/drag water to leave ripples. Golden hour, Lantern night, and Clear morning change the time of day. Tune waves, hour, wind, and tide. The contextual hint offers sitting when the bench is in reach.

**Glass Blocks:** a reusable glass filter that synthesizes rounded panes, dark structural joints, uneven glass surfaces, refraction, green-tinted absorption, Fresnel reflections and edge highlights over a clean background image. Hand-poured, Clear blocks and Frosted presets change the material. Drag to perturb one pane, right-drag shifts the viewing angle and background, and scroll inspects the result. Tune refraction, thickness, surface ripple and column count; the row count adapts to the picture aspect ratio. Refraction at zero shows the unfiltered image for comparison. Pane boundaries stay fixed and ripple transport is isolated to the touched pane.

Drop a local image onto Glass Blocks or use its photo button / File → Open Image for Glass (Command–Shift–O). ImageIO honors orientation and converts to sRGB, downsampling to a maximum 2048-pixel edge before GPU upload. Unsupported/corrupt files leave the current image intact. The adjacent restore button returns to the bundled seaside image. The selected file URL lasts for the session; decoded images and wave state are released on scene exit. A missing file on reentry falls back to the bundled image. The default is an unfiltered frame from Molten’s own Sakura Cove renderer, not the glass reference photograph. JPEG/PNG/HEIC and other ImageIO-supported still images work; animated inputs use their first frame. Nothing is uploaded or copied to a photo library.

The glass effect uses an approximate two-interface refraction model over a flat background, with procedural surface normals and mip-based diffusion for frosted glass. It is not a reconstruction of hidden scene geometry. A fixed 256-square GPU wave field uses 60 Hz steps and bounded catch-up. No HDR history or acceleration structure is allocated for this scene. Paused views settle after one frame; hidden-window scheduling is shared with the other scenes.

**River Garden:** a small stream with mossy banks, three resonant stones and three responsive plants. Pick up any stone, move slowly to place it, or flick to skip it. Scroll while holding a stone to lift it; scroll otherwise to zoom. Each stone has a distinct pitch. Drag a plant to bend its leaves, then release it for a soft higher tone and a ripple at the bank. Passing water waves bend nearby leaves. Click or trace the stream to disturb the water. Morning dew, Moon garden and Golden hour change the light. Tune ripple strength, resonance, water clarity and lighting. The fixed view keeps direct manipulation predictable.

Sound starts only on interaction; the speaker button mutes it. The garden uses a bounded 256-square wave field (two RG32F textures, 1 MiB), small fixed-step CPU mechanics, and an eight-voice procedural AVAudioSourceNode. No microphone, camera, model download or network call is required. Sound and rendering stop when the window is hidden, minimized, occluded or paused; the scene also sleeps once the water and leaves settle. Closing the last window quits Molten. Switching scenes releases the wave textures and audio engine. Quality changes and resize preserve the garden state. The water, plant springs and stone skipping are artistic interaction models.

**Prismatic Turbine:** a three-bladed wind turbine inside a dense, colored particle wake, inspired by the supplied reference. The tower, nacelle, hub and twisted airfoils are real 3D geometry. Fixed-size GPU tracer buffers move through a procedural velocity field with a slower core, three helical tip vortices, spreading flow and coherent turbulence. This is an artistic wake model, not calibrated CFD or an engineering prediction. Color is an aesthetic radial/eddy mapping rather than a measured physical scale. Prismatic wake, Glacial flow and Ember vortices change the palette.

Drag to stir the wake; Shift-hold brakes the rotor, then release to spin back up. Right-drag orbits and scroll zooms. Wind controls transport speed, with separate rotor speed, turbulence and particle density controls. Eco/Balanced/High/Cinematic use 120,000/300,000/900,000/1,400,000 persistent particles. Density changes opacity without allocating more particles. Advection uses fixed 60 Hz steps and bounded catch-up; pause freezes both the particles and the rotor while orbit/zoom remain available. A depth buffer hides particles behind the turbine. One HDR render target resolves directly to the display without temporal histories or CPU readbacks. Switching scenes releases tracer buffers, mesh and render targets. The existing hidden/minimized/occluded rendering policy applies. The scene is silent and needs no model, network, microphone or new image assets.

These scenes are interactive visual models. They do not claim scientifically calibrated fluid, magnetic, crystal, optical, or geological behavior.

- **Paper Reverie:** five curved pastel folders with tab labels, paper fibers, soft shadows, shallow depth of field, and fifteen fluttering notes. Click a folder to open it, drag to flex/lift it, and click again or click the white margin to settle it. Hover shifts focus gently; right-drag changes the view and scroll zooms. Pastel archive, Botanical paper, and Lavender dusk offer three palettes. Tune spread, paper breeze, soft focus, and grain. The scene is a procedural paper sculpture, not a file browser.

**Liquid Glass Lab:** an interactive playground built with Apple's public SwiftUI `GlassEffectContainer`, `glassEffect`, `glassEffectID`, and matched-geometry transitions. Start with seven pieces: drag and flick them, bring them together to fuse their glass surfaces, or double-click one to expand its controls. Stretch a piece, cycle through round, capsule, squircle and flower shapes, split it, or use Gather / Ribbon / Scatter to rearrange the group. The surfaces merge visually while the pieces retain their identities. The toolbar switches Clear and Regular glass. The More menu adds/removes pieces, changes the selected shape, or fills the scene to its hard maximum of 24 pieces.

Misty lake, Rolling hills and Quiet coast use the three approved generated landscape images beneath the native material. Shorelines, reflections, paths and foliage make the glass's distortion visible without large background lettering or patterned artwork. The photographs keep their original colors and fill the window with a centered crop, preserving their proportions. They are still by default; optional Backdrop drift adds a very slow, small camera movement. Fusion changes the native container's spacing; the tuning panel also controls size and tint. Shape and optical rendering come from Apple's compositor. Metal renders only the background; there is no replacement glass shader, private API, model download or capture process. Native optics such as refraction and edge highlights remain system-controlled.

Only the selected landscape texture is retained, and leaving Liquid Glass Lab releases it. A still background reuses its rendered image during chain physics updates. Images are bundled locally in `Resources/NativeGlassLandscapes`, with no network requests or per-frame image decoding.

Drag the center of a piece to move it. Hover an eligible rim to see a small local bulge and glint, then hold and pull outward. Two native glass lobes develop throughout the pull, with a reserved child identity and gradual area transfer. Their facing edges gather a narrower highlight as tension grows. At the split threshold the visible child is committed at the same position and size, and the fixed stage keeps ownership of dragging. A subtle local recoil finishes in 240 ms using the existing scene clock. Releasing early retracts the lobes over 180 ms; reduced-motion, hidden or paused states cancel immediately. Small pieces and a full 24-piece collection do not advertise a grip; accessibility hints explain those limits. All feedback stays in the material, with no floating instruction card, percentage, direction arrow or independent timer. The split preserves combined area and the source shape. Escape cancels a gesture. Double-click opens controls without losing the piece's identity.

Nearby pieces snap into magnetic connections. Use the chain button to arrange a connected chain, then pin any selected piece with the pin button or its context menu. Drag the other end to swing and stretch the chain; a hard pull breaks its connection. Thin tethers identify stretched connections between separated glass surfaces. Each piece has at most two links, with no closed cycles or branching. The magnetism toggle detaches the links. These are damped artistic spring mechanics, not a calibrated physical material simulation.

The trackpad button enables or mutes haptics for a user-triggered snap, tear, pin or detach. Feedback uses public AppKit APIs, is throttled, and is dispatched only while Molten is visible and its window has focus. Physics settling produces no feedback by itself. Actual vibration depends on a supported Force Touch trackpad and system preferences. No audio engine is added.

Mechanics use fixed 120 Hz steps, at most eight catch-up steps, and the existing MTKView scheduling loop. There is no additional timer or display link. Motion sleeps when settled, with a bounded settling interval after release; hidden, paused, focus-lost and reduced-motion states discard residual momentum. At most 24 bodies and 23 links exist. Removing a piece cleans its links and pin. Resizing cancels incomplete tears and keeps the pieces inside the new stage.

Pausing stops the backdrop and chain physics while allowing direct editing. Reduce Motion removes spring/coasting motion and stops the background loop; Reduce Transparency provides an opaque backing. With backdrop drift at zero, recurring draws stop once the chain settles. Hidden/minimized/fully occluded windows stop rendering, and leaving the scene removes the hosting view and its interaction model. Native animations are finite and event-driven, with no extra polling timer. Closing the last window quits the app.

Quality controls the Metal artwork resolution. FPS caps both the backdrop and updates to the chain model; the fixed physics step keeps trajectories independent of that cap. Native glass remains at display resolution and macOS renders its material and transitions. The performance overlay and offscreen benchmarks explicitly report **backdrop-only** timings; they do not measure the native compositor or WindowServer memory. Save Image is disabled for this scene because a Metal readback would omit the glass; a normal macOS screenshot captures the complete composition.

## Controls

Choose any of the 28 scenes from the top picker. The bottom bar controls its preset, main parameter, quality, frame-rate cap, pause, reset, and optional performance overlay. The slider icon opens the scene's three additional controls and, for animated scenes, animation speed. Controls apply immediately; per-scene tuning is retained while the app is open.

- Command–1 through Command–9: the first nine scenes. All 28 are also in the Scene menu.
- Space: pause/resume.
- Command–R: reset.
- Command–I: performance overlay.
- Command–S: save the rendered Metal scene as a PNG (unavailable in Liquid Glass Lab, whose native glass is composited separately).
- Command–O: choose local music for the turntable.
- Command–Shift–O: choose an image for Glass Blocks.
- Command–M: minimize.
- Control–Command–F: full screen.
- Command–W: close. Closing the last window quits the app.

Except for the fixed-view River Garden, right-drag orbits the 3D scenes and shifts the limited depth of the image-based scenes; scroll zooms, or moves the camera through the fractal. The on-canvas hint shows each scene's direct controls. Reset restores both simulation and camera.

The turntable starts muted. Its speaker button enables quiet procedural water/vinyl ambience. Use the music-note button, Command–O, or drop an audio file on the pond to play a local track. Record speed and direction drive interpolated sample playback, including reverse scratching; the lifted tonearm fades to silence. Tracks loop. Mono/stereo files supported by AVAudioFile are decoded into at most 64 MiB of signed 16-bit PCM (roughly six minutes of stereo at 44.1 kHz); oversized files produce an explanatory message and are not truncated. Audio pauses when the scene is paused or the window is hidden, occluded, minimized, or sleeping. Leaving the koi scene releases its audio engine and decoded track. No autoplay on app launch and no streaming or network access.

The atelier scenes use a fixed 256² damped-wave field and bounded 60 Hz updates. Koi steering and wake state stay on the GPU; a few CPU mechanical values drive the turntable and audio without readbacks. Printed surface grain follows the portal geometry. The portal uses an analytic distance-field renderer and an artistic second-space aperture, not recursive general-purpose portal rendering. The turntable is a layered 2.5D illustration. These are intentionally stylized interpretations of the supplied references.

**Cinematic** adds higher ray/volume detail and progressive sampling. The static light lab and holographic card settle at 8, 16, 32, or 128 samples in Eco, Balanced, High, or Cinematic, then stops drawing. In sampled animated cinematic scenes, pause animation to refine a still image to 128 samples in Cinematic. The four image-based scenes need one frame and no accumulation. Moving the camera, tuning controls, changing presets, or resizing invalidates history. Interaction in Cinematic uses a smaller preview target and returns to full resolution on release. Paused refinement uses an in-app accumulation pipeline. The animated river additionally uses Apple MetalFX denoising and temporal reconstruction on supported devices; the other scenes retain their existing resolve paths. No scene generates interpolated frames.

Minimizing, hiding, fully covering, closing, or sleeping the app stops the display loop, including unfinished refinement. A paused scene draws only on input or while completing a requested Cinematic still. Converged stills stop submitting scene passes. No polling timer runs in the background. Only the active scene’s simulation resources are retained.

Quality scales output resolution and, for sampled scenes, ray/volume detail. The 2D persistent simulations use fixed grids (256² for terrain, 384² for water, crystals, and patterns), independent of the window's Retina resolution. Fixed simulation ticks keep their evolution stable across frame-rate caps. Their state textures use approximately 3–4.5 MiB while active and are released when leaving the scene. Rendering targets, pipelines, and other app allocations are additional.

The cinematic and immersive scenes normally cap their longest render dimension at 800/1152/1536/1920 pixels across the four quality levels. Sakura Cove and Glass Blocks use 800/1152/1920/2560-pixel caps. The detailed river uses 800/1280/1920/3024-pixel output caps. Its animated Balanced/High/Cinematic modes use MetalFX at 1×/1.5×/2× reconstruction ratios; Eco and paused refinement render directly. Very small test targets also render directly. Liquid uses a 48³/64³/80³/96³ reconstruction field and a fixed particle budget; fire uses a 40³/48³/64³/72³ grid. Liquid ticks at 120 Hz and combustion at 60 Hz, with bounded catch-up work. Changing their quality reallocates and restarts their simulation. Images, accumulation, volumes, and particle storage are allocated only for the active new scene and released on leaving it. Pipeline objects remain cached.

Model limits: the optical lab samples RGB wavelength bands, uses a finite photon grid and bounce budget, and simplifies overlapping dielectric media. It is not a reference spectral renderer. Liquid uses position-based density constraints and a density-sampled buoyancy approximation rather than a full FLIP/rigid-body solver. Pouring reuses particles once the finite budget is filled. Fire uses a coarse incompressible grid with a simple combustion model. Planetary terrain/weather and the cathedral are procedural art. These tradeoffs make the models interactive on this Mac.

The reef uses a persistent 32 × 24 × 32 current field, with damped advection and pointer impulses, plus fixed 60 Hz fish/plankton updates. Eco/Balanced/High/Cinematic use 192/384/640/960 fish and 2,048/4,096/8,192/12,288 plankton. Fish compute local separation, alignment, and cohesion on the GPU; jellyfish use slower steering and pulse motion. Opaque geometry is depth tested and translucent bells, tentacles, and plankton are blended in one instanced render pass. Sunlight shafts, absorption, seafloor caustics, and current glow complete the water rendering. Only the selected scene's resources remain allocated. Changing quality restarts reef state.

The card's foil is an artistic grating-inspired spectral shading model, with a layered parallax illustration and a thin analytic body; it does not reconstruct a scanned physical card. Reef schooling and currents are bounded visual models, and kelp/tentacles follow the flow with procedural deformation. Water shafts and caustics are approximations. Jellyfish are translucent shaded geometry, not ray-traced refractive volumes. No ecological or fluid-engineering accuracy is claimed.

The river stores a free-surface elevation/excitation field, a velocity-disturbance field, and a cached bathymetry field on the GPU. Each fixed 60 Hz tick contains two 120 Hz water substeps. The substeps advect momentum, accelerate it from the free-surface pressure gradient, and update height from depth-weighted flux divergence. Wet/dry and principal boulder boundaries block disturbance flux. A prescribed depth-dependent steady current and localized wake forcing drive the stream; this is not a mass-conserving full river hydraulics solver. The channel has varying width, gravel bars, pools, irregular banks, and a descending water level. CPU mesh creation, GPU bathymetry, optics, and camera clearance share matching ground and water-level formulas, checked numerically by the river test.

Eco/Balanced/High/Cinematic use 192 × 384, 256 × 512, 384 × 768, and 512 × 1024 grids, with at most four catch-up ticks per frame. They retain 12,288/32,768/65,536/131,072 organisms. Excitation is advected and decays; quiet water stays dark. Organisms glow in disturbed water, and only sufficiently agitated water emits spray. Particles stranded in dry shallows are reseeded instead of gathering into bright shoreline outlines. A small separate population represents fireflies. State stays on the GPU; the interactive loop performs no CPU simulation or readback.

The forest is original procedural mesh geometry built once on scene entry: irregular stones with normals derived from their actual shape, submerged gravel, shorter buried roots, branches and individual leaves, sedges, ferns, leaf litter, fallen twigs, and a second layer of distant trees. A denser grid follows the winding channel. The same Metal acceleration structure is used for primary visibility, reflections, refraction, shadows, and diffuse probes. Geometry remains procedural and static; it is not a scanned forest.

Five scanned material sets from [Poly Haven](https://polyhaven.com/license) supply river gravel, stone, willow bark, forest floor, and moss. Each includes a 1,024 × 1,024 color map, tangent normal map, and packed ambient-occlusion/roughness/metalness map. Color is decoded as sRGB; data maps stay linear. Mipmapped texture arrays use triplanar projection and distance-dependent sampling. All maps are bundled locally under CC0; the app downloads nothing. Exact source URLs, checksums, and license information are in `Resources/RiverMaterials/sources.json` and `LICENSE.txt`.

Water uses displaced normals, dielectric Fresnel reflection, traced bed refraction with depth-dependent absorption, and localized emission from simulated excitation. The previous cellular glow pattern and blanket sparkle layer are removed. Visibility-tested samples of emissive river patches illuminate nearby surfaces. A quarter-resolution volume pass integrates drifting mist with geometry shadows, followed by depth-aware composition. Organisms and spray are rasterized after denoising, then restrained bloom is added. The closer default camera emphasizes the water and riverbed.

MetalFX receives linear HDR radiance, normalized depth, camera and water-advection motion vectors, world-space normals, diffuse/specular albedo, roughness, specular hit distance, and a reactive mask for changing water. A fixed exposure hint matches the tonemapper. Camera cuts, tuning changes, reset, resize, and reconstruction transitions invalidate temporal history. Pausing bypasses MetalFX so still accumulation is deterministic. Orbit height follows the terrain and water level. Water, organisms, spray, fireflies, and mist animate; forest geometry is static.

The river remains an interactive visual model. It does not implement calibrated three-dimensional hydraulics, spectral water optics, biological organism behavior, or a fully converged global-illumination path tracer. Underwater focused light remains an approximation. Changing quality restarts state; switching scenes releases the river's geometry, acceleration structure, particle buffers, scanned materials, bathymetry, render textures, and denoiser. Pipeline objects remain cached. Hidden/minimized/occluded scheduling is unchanged.

GPU milliseconds are measured from completed Metal command buffers. GPU MB means allocations reported by Metal, not total application RAM. FPS is measured, not just the requested cap. No CPU-versus-GPU speedup is claimed without a comparable benchmark.



Paper Reverie generates its curved sheets in Metal and uses five bounded 120 Hz spring states for interaction. It retains one HDR color target with a filtered mip pyramid, depth and shadow targets, and an 80 KB monochrome label atlas only while selected. No scene graph, per-frame mesh uploads, temporal histories, capture buffers, or downloaded assets. A captured press position/serial preserves quick clicks between display frames. Pause freezes motion; quality and resize preserve open folders. Hidden/minimized/occluded rendering follows the existing stop policy, and closing the last window quits the app.

## Build

Requires macOS 26+, Apple silicon, and Apple Command Line Tools with the macOS 26+ SDK.

```sh
bash build.sh
```

The signed app is written to `.build/output.noindex/Molten.app`. Development bundles stay outside Spotlight’s app search. Local builds use ad-hoc signing by default. Set `MOLTEN_SIGNING_IDENTITY` to your own identity for a signed build. The neutral `org.example.molten` identifier gives this copy its own preferences. Choose your own identifier and signing team for distribution.

The Metal source compiles through the public `MTLDevice.makeLibrary(source:options:)` API at launch. This supports a Command Line Tools installation without the optional offline Metal compiler. There are no downloaded shaders or code.

## Verification

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --self-test --output /tmp/molten-check
```

The offscreen suite executes the real GPU pipelines, checks all 81 Metal-rendered presets; the native glass suite checks the remaining three looks, detects blank renders, verifies interaction and animation, exercises every quality level and odd-sized textures, checks the new tuning controls and paused redraws, switches repeatedly between scenes, saves PNGs for visual inspection, and records timings in `self-test.json`.

Additional checks:

```sh
# Real Metal API and shader validation; no windows.
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 .build/output.noindex/Molten.app/Contents/MacOS/Molten --self-test --output /tmp/molten-validation

# Thirty simulated seconds per new persistent simulation, sustained interaction,
# finite state, erosion/growth, pause, refresh-rate consistency, resource release.
.build/output.noindex/Molten.app/Contents/MacOS/Molten --stress-test --output /tmp/molten-stability

# Native control bindings and layouts at three sizes. No window is ordered,
# activation is prohibited, and user preferences are not read or changed.
.build/output.noindex/Molten.app/Contents/MacOS/Molten --verify-controls
```

For a live development session, `--diagnostics /absolute/path.json` writes a small diagnostic record during rendering and on lifecycle transitions. This option is off in normal use.

The headless performance benchmark opens no windows and separates particle simulation from drawing:

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --benchmark --scene particles --output /tmp/molten-performance.json
```

Add `--fullscreen` for a 3024 × 1898 drawable, `--drag` for sustained pointer attraction, or `--frames 120` for a longer sample. These are offscreen GPU measurements; they exclude display presentation and are not claims of achieved frame rate or battery life.

Omit `--scene` to measure all 28 scenes, or use a key such as `koi`, `portal`, `river`, `holographic`, `reef`, `black-hole`, `ferrofluid`, `ocean`, `aurora`, `terrain`, `membranes`, `crystals`, or `patterns`. Measurements run serially to avoid contaminating one scene's GPU timings with another benchmark.

The expansion's full-screen stress benchmark covers every new preset with held pointer input, maximum controls, and double simulation speed:

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --benchmark --new-scenes --all-presets --max-controls --quality high --fullscreen --drag --output /tmp/molten-extremes.json
```

## Apple APIs

AppKit, NSGlassEffectView, MetalKit, Metal, MetalFX, QuartzCore, UniformTypeIdentifiers, and AVFoundation. The turntable uses Apple's [AVAudioSourceNode](https://developer.apple.com/documentation/avfaudio/avaudiosourcenode) and [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine), with atomically published controls and no file I/O or locks in its audio callback. Glass requires a device supporting Metal ray tracing. FanPilot is separate: Molten does not call SMC, change clocks, modify GPU memory limits, or switch power modes.


The cinematic suite adds 128-sample convergence, a check that converged scenes submit no more scene passes, camera/control/resize history invalidation, atmospheric entry, fractal flight, thirty simulated seconds with maximum controls and sustained input, bounded particles and neighbor occupancy, frozen state during pause, and release of inactive resources:

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --cinematic-test --output /tmp/molten-cinematic

# Restrict performance work to cinematic and immersive scenes.
.build/output.noindex/Molten.app/Contents/MacOS/Molten --benchmark --cinematic-scenes --quality high --fullscreen --output /tmp/molten-high.json
.build/output.noindex/Molten.app/Contents/MacOS/Molten --benchmark --cinematic-scenes --quality cinematic --fullscreen --output /tmp/molten-cinematic-performance.json
```

Native control verification also checks the rendering policy for hidden, paused, converged, refining, and pending-input states. All verification commands run offscreen; control verification prohibits activation and verifies the foreground application is unchanged. Updating the installed bundle does not require launching or restarting the app.

Apple references: [Metal sample code](https://developer.apple.com/metal/sample-code/) and [3D textures](https://developer.apple.com/documentation/metal/mtltexturetype/type3d). The original Glass scene uses Metal's hardware ray-query API. The new optical scene traces its small analytic scene directly in Metal compute kernels.

The immersive integration suite checks card face/tilt/reverse, retained lighting, convergence at all four quality levels, fish and plankton state, current wakes, schooling response, 30/60 Hz parity, a thirty-second stress run, pause, and resource release. It saves actual GPU renders for visual inspection:

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 .build/output.noindex/Molten.app/Contents/MacOS/Molten --immersive-test --output /tmp/molten-immersive
.build/output.noindex/Molten.app/Contents/MacOS/Molten --benchmark --scene reef --all-presets --quality high --fullscreen --output /tmp/molten-reef-performance.json
```

The river integration suite verifies detailed mesh geometry, active MetalFX denoising, identical surface and organism state at 30/60/120 Hz, click ripples, downstream wake transport and decay, paused state, maximum-control stress at Balanced and Cinematic quality, dry boundaries, and resource release. It also saves the three presets and close-up interaction renders:

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 .build/output.noindex/Molten.app/Contents/MacOS/Molten --river-test --output /tmp/molten-river
.build/output.noindex/Molten.app/Contents/MacOS/Molten --cinematic-test --scene river --output /tmp/molten-river-cinematic
.build/output.noindex/Molten.app/Contents/MacOS/Molten --benchmark --scene river --all-presets --quality high --fullscreen --output /tmp/molten-river-performance.json
```

Native control verification also sends synthetic mouse events directly to an unshown view to verify card tilt, Shift-drag lighting, double-click flipping, and reef/river/koi/portal orbit, stirring, and release. It posts no desktop input and verifies foreground ownership remains unchanged. Installation replaces the app bundle atomically without launching it; reopen Molten manually to load a new version.

The atelier suite verifies 30/60/120 Hz parity, persistent waves, pause, bounded fish, twenty seconds of maximum-control stress, record scratching/inertia, fader/tonearm/motor hit testing, actual local PCM decoding, stereo/reverse playback, interpolation boundaries, mute fades, and the production AVAudioEngine graph in offline manual-rendering mode. No sound is sent to the hardware during testing. It also checks the shared hidden/paused audio policy and saves full-size renders of the pond, portal orbit, approach, and next world.

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 .build/output.noindex/Molten.app/Contents/MacOS/Molten --atelier-test --output /tmp/molten-atelier
```


## Sakura Cove implementation and checks

The cove is an original mesh diorama, with 5,250 individually modeled blossoms in Balanced/High/Cinematic (2,688 in Eco), a small articulated character, and 384 persistent falling/landed/floating petals. GPU deformation animates the tree, petals, clothing, gait and lantern. A refittable Metal acceleration structure supplies primary visibility, shadows, reflections and refraction from the same geometry. Three existing bundled CC0 material sets provide stone, bark and seabed detail. The other materials are procedural. No new asset downloads or external runtime were added.

Water combines directional swells, a 256-square persistent damped-wave field, traced reflection/refraction, depth-dependent extinction, glints, shoreline foam and approximate caustics. Time of day sets sun/moon and ambient lighting; the lantern casts local shadows. This is an artistic water model, not a calibrated coastal fluid simulation or full global-illumination path tracer.

Gameplay uses a small CPU state at fixed 60 Hz, with camera-relative acceleration, normalized diagonal input, swept small movement steps against the terrace and furniture boundaries, a seated state, and a damped lantern pendulum. It never reads GPU data during interactive use. There is no jumping, swimming, combat or quest system. The cove is a playable ambient diorama. Pause freezes gameplay, water, wind animation and particles; orbit and still-image refinement remain available. Losing focus releases held movement keys. Quality changes and Reset restart the scene. Scene exit releases geometry, textures, acceleration and simulation storage. The existing hidden-window scheduling policy applies to the cove.

The cove suite exercises real GPU state and gameplay, including 30/60/120 Hz parity, walking/running, blocked edges and furniture, key release, walking to the bench, sitting/standing, free-camera flight, lantern impulses, pause, a 30-second stress run, and resource release. It produces actual GPU captures, without creating a window:

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 .build/output.noindex/Molten.app/Contents/MacOS/Molten --cove-test --output /tmp/molten-cove
.build/output.noindex/Molten.app/Contents/MacOS/Molten --cinematic-test --scene cove --output /tmp/molten-cove-cinematic
.build/output.noindex/Molten.app/Contents/MacOS/Molten --benchmark --scene cove --all-presets --quality high --fullscreen --frames 120 --output /tmp/molten-cove-performance.json
```

Native control verification also checks the actual cove W/A/S/D, Shift, E, C, R/F, release and reset event handlers. Repeated E/C keydown events cannot repeatedly toggle actions. No event is posted to the desktop. The public Metal [acceleration-structure refit API](https://developer.apple.com/documentation/metal/mtlaccelerationstructureusage/refit) updates the animated geometry; it is built once on scene entry and its scratch storage is reused.

Glass filter verification (offscreen, no app activation):

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --glass-effect-test --movie --output /tmp/molten-glass-effect
.build/output.noindex/Molten.app/Contents/MacOS/Molten --cinematic-test --scene block-glass --output /tmp/molten-glass-stress
```


## River Garden verification

The garden suite verifies all three stone hit targets and distinct voices, continued motion when another stone is picked up, quick taps between display and physics frames, placement and skipping at 30/60/120 Hz, stale-velocity rejection, focus cancellation, plant bending/release/sound/ripples, pause and settling, constant wave allocations and scene teardown. It also checks finite stereo audio, bounded voices/events, silence before touch, tail decay and the native audio graph in offline mode. Tests create no windows or live audio output. The optional movie records actual Metal frames and the same procedural audio sampler.

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --garden-test --movie --output /tmp/molten-garden
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 .build/output.noindex/Molten.app/Contents/MacOS/Molten --garden-test --output /tmp/molten-garden-validation
.build/output.noindex/Molten.app/Contents/MacOS/Molten --cinematic-test --scene river-garden --output /tmp/molten-garden-stress
```

The native control check also verifies retained garden press/release events, coalesced motion, focus cancellation, the fixed camera, and unchanged foreground-app ownership. Trackpad haptics use AppKit's default haptic performer for grabs and stronger contacts; availability follows the input device and system settings. Headless tests do not verify the physical sensation.


## Turbine verification

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --turbine-test --movie --output /tmp/molten-turbine
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 .build/output.noindex/Molten.app/Contents/MacOS/Molten --turbine-test --output /tmp/molten-turbine-validation
.build/output.noindex/Molten.app/Contents/MacOS/Molten --cinematic-test --scene turbine --output /tmp/molten-turbine-stress
```

The headless suite checks distinct particle initialization, identical state at 30/60/120 fps, finite bounded tracers, pause/orbit/resize, rotor braking and restart, pointer disturbance, wind transport, twenty simulated seconds at maximum controls, bounded allocation at all qualities, and complete teardown. The optional eight-second movie records real GPU frames without opening or activating a window. Reported GPU times exclude display presentation and are not live frame-rate or battery-life measurements.

### Paper Reverie checks

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --paper-test --movie --output /tmp/molten-paper
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 .build/output.noindex/Molten.app/Contents/MacOS/Molten --paper-test --output /tmp/molten-paper-validation
```

The headless paper test verifies identical 30/60/120 Hz spring motion, quick clicks, folder opening and closing, drag cancellation, pause and resize, bounded catch-up, sustained maximum controls, constant allocations, four quality budgets, and resource release. It saves three preset images, an opened-folder view, an orbit view, an optional movie, and GPU timings. No application window is shown.

## Native Liquid Glass verification

```sh
.build/output.noindex/Molten.app/Contents/MacOS/Molten --native-glass-test --output /tmp/molten-native-glass
Molten.app/Contents/MacOS/Molten --verify-controls
```

The native suite checks drag/release/cancellation, split identities, the 24-piece cap, minimum expanded-control sizes, four shape states, arrangements and resized bounds, reduced motion, actual SwiftUI hosting/layout with both glass variants and all three backdrops, deterministic paused Metal output, pixel budgets, and bounded resource use across scene changes. Landscape checks cover stationary defaults, optional drift, reduced-motion output, texture reuse, an 8 MiB active-photo budget, release on scene exit, and wide/tall crop renders. Control verification also checks AppKit-to-SwiftUI bindings, stage separation from app controls, reset, focus loss, the incomplete-export guard, and hosting-view deallocation after scene exit. Tests run without displaying or activating a window. The existing GPU self-test covers the other 30 scenes and includes native-backdrop scene switches in its teardown checks.

The interaction suite also checks hover/grab boundary agreement across shapes and sizes, transparent-corner rejection, overlapping pieces, small/full states, deduplicated idle hover, material grip hit testing and lifecycle cleanup; partial and completed tears, inward-edge rejection, area preservation, continuous child dragging, pinned parents, automatic magnetic attachment, matching 30/60/120 Hz spring trajectories, motion transfer through anchored chains, breakaway, resting sleep, capped catch-up, lifecycle cancellation, haptic dispatch throttling and mute, bounded 24-piece stress, and idle-backdrop wake/sleep policy. Its CPU timing measures only model updates, excluding SwiftUI layout and system compositing. Tests replace the haptic callback with an event recorder; they do not vibrate the user's trackpad.

The material affordances use a small local deformation of the native glass contour and a neutral light/dark glint on the touched rim. During a pull, the glint concentrates on the facing edges of the growing lobes; successful separation triggers a 240 ms local recoil using the existing visible-scene clock, then returns to idle even if the pointer stays down. There are no tear popups, progress percentages, direction arrows, additional glass surfaces or independent timers. Reduced Motion keeps the static glint and suppresses optional bulging/recoil. Accessibility hints and the named Split action remain available. Early release retracts over 180 ms. Material checks verify local deformation, unchanged neighboring pieces, hit testing on the bulge, reduced motion and immediate lifecycle cancellation; `material-contours-only.png` shows actual shape and rim overlays on bright/dark backgrounds, excluding native glass optics.

The tear continuity checks sample the actual displayed lobes immediately before and after the split across 288 combinations of shape, scale, stretch and direction. They compare glass identities, positions, sizes, unchanged neighbors, area, deformed rim continuity and continued stage-owned dragging. Hidden native-host checks step through the same transition at compact, standard and wide sizes and reject host replacement, viewport changes or gesture cancellation. The geometry contact sheet shows actual shape geometry only, not Apple's optical compositor.

Native glass's appearance, interaction smoothness, physical haptic feel and compositor/WindowServer memory are not visually or quantitatively verified by these headless tests. Files named `backdrop-only-*.png` contain only the Metal artwork and are not previews of the finished playground. A visible-window evaluation is needed for those remaining measurements.

Public API reference: [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).
