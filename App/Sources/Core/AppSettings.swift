import Foundation
import SwiftUI

/// User-facing settings. App-only preferences live in UserDefaults; emulator settings are also
/// written to <Documents>/Azahar/config/ios-config.ini, which the core reads (keys are
/// Azahar's own setting names, so the file matches a desktop qt-config.ini).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum JITMode: String, CaseIterable, Identifiable {
        case auto, legacy, universal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "自动"
            case .legacy: return "传统（iOS 17/18、非 TXM 设备）"
            case .universal: return "StikDebug 通用脚本（iOS 26 TXM 设备）"
            }
        }
        var environmentValue: String { rawValue }
    }

    enum ScreenLayout: Int, CaseIterable, Identifiable {
        case stacked = 0, single = 1, largeSmall = 2, sideBySide = 3, hybrid = 4
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .stacked: return "上下排列"
            case .single: return "单屏"
            case .largeSmall: return "大屏 + 小屏"
            case .sideBySide: return "左右并排"
            case .hybrid: return "混合"
            }
        }
        /// Value of Settings::LayoutOption on non-Android builds
        /// (Default, SingleScreen, LargeScreen, SideScreen, SeparateWindows, HybridScreen, Custom).
        var coreValue: Int {
            switch self {
            case .stacked: return 0
            case .single: return 1
            case .largeSmall: return 2
            case .sideBySide: return 3
            case .hybrid: return 5
            }
        }
    }

    /// What the in-game status bar shows about speed (Settings → 开发者选项).
    enum PerfOverlay: Int, CaseIterable, Identifiable {
        case off = 0, fps = 1, detailed = 2
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "不显示"
            case .fps: return "只显示帧率"
            case .detailed: return "详细（JIT、帧率、速度、帧时间）"
            }
        }
        var shortTitle: String {
            switch self {
            case .off: return "性能信息关"
            case .fps: return "帧率"
            case .detailed: return "详细"
            }
        }
    }

    // MARK: Graphics
    @AppStorage("resolutionFactor") var resolutionFactor = AppSettings.defaultResolutionFactor { willSet { objectWillChange.send() } }
    /// Apple Vision Pro shows the screens metres wide, so it renders at up to 4× (1600 × 960 per
    /// eye). Without the Increased Memory Limit entitlement (free developer accounts) the app gets
    /// much less memory and 4× stereo can get it closed by the system, so the default follows the
    /// memory available at launch. An explicit choice (setting, -resolutionFactor) always wins.
    static var defaultResolutionFactor: Int {
        #if os(visionOS)
        return VisionMemoryBudget.resolutionFactor
        #else
        return 2
        #endif
    }
    @AppStorage("asyncShaders") var asyncShaders = true { willSet { objectWillChange.send() } }
    @AppStorage("textureFilter") var textureFilter = 0 { willSet { objectWillChange.send() } }
    /// Azahar texture_sampling: 0 = GameControlled (default), 1 = NearestNeighbor, 2 = Linear.
    @AppStorage("textureSampling") var textureSampling = 0 { willSet { objectWillChange.send() } }
    /// Custom texture packs from Azahar/load/textures/<titleID>/ (read at game boot), on by default.
    @AppStorage("customTextures") var customTextures = true { willSet { objectWillChange.send() } }
    /// Load the whole pack into RAM at boot (slower start, no first-use stutter).
    @AppStorage("preloadTextures") var preloadTextures = false { willSet { objectWillChange.send() } }
    /// Vision Pro: fixed pitch of the top (3D) screen in degrees, top edge away when positive,
    /// like looking down at a 3DS held at an angle. 0 = upright (the old behavior). Layout only.
    @AppStorage("visionScreenTiltDegrees") var screenTilt = 0.0 { willSet { objectWillChange.send() } }
    @AppStorage("linearFiltering") var linearFiltering = true { willSet { objectWillChange.send() } }
    @AppStorage("vsync") var vsync = true { willSet { objectWillChange.send() } }
    @AppStorage("accurateMul") var accurateMul = false { willSet { objectWillChange.send() } }
    /// Delay GSP "GPU done" interrupts like real hardware (Azahar's simulate_3ds_gpu_timings). Some
    /// games are said to stall when they arrive instantly. Off by default: on Apple Vision Pro it
    /// did not stop Super Mario 3D Land's stalls and Azahar still calls it experimental.
    @AppStorage("gpuTimings") var gpuTimings = false { willSet { objectWillChange.send() } }
    /// Apple renderer workarounds, each switchable to bisect stalls (patch 0010). Stability
    /// defaults: no pipeline fast-path probe, wait for small-draw pipelines, synchronous submits.
    @AppStorage("vkPipelineFastPath") var vkPipelineFastPath = false { willSet { objectWillChange.send() } }
    @AppStorage("vkSkipUnreadyDraws") var vkSkipUnreadyDraws = false { willSet { objectWillChange.send() } }
    @AppStorage("vkAsyncQueueSubmits") var vkAsyncQueueSubmits = false { willSet { objectWillChange.send() } }
    /// Re-signal the GSP interrupt event when its relay queue has not drained for 30 vblanks.
    @AppStorage("gspResignalStalled") var gspResignalStalled = false { willSet { objectWillChange.send() } }
    @AppStorage("diskShaderCache") var diskShaderCache = true { willSet { objectWillChange.send() } }

    // MARK: Performance
    @AppStorage("cpuClock") var cpuClock = 100 { willSet { objectWillChange.send() } }
    /// "Auto": 50 % without JIT, 100 % with JIT. Measured on an iPhone 14 Pro Max: without JIT the
    /// interpreter keeps Pokémon Sun at full speed at 50 % (25 % starves its loading threads and
    /// freezes the picture at scene changes; 100 % runs at roughly half speed).
    @AppStorage("cpuClockAuto") var cpuClockAuto = true { willSet { objectWillChange.send() } }
    /// Auto is 100 % with or without JIT. Without JIT it used to be 50 %: the interpreter kept full
    /// speed, but games got half the CPU time per frame, and Super Mario 3D Land hung loading a
    /// level (every hang log on the device had Core_CPUClockPercentage: 50).
    var effectiveCPUClock: Int { cpuClockAuto ? 100 : cpuClock }
    @AppStorage("frameLimit") var frameLimit = 100 { willSet { objectWillChange.send() } }
    @AppStorage("fastForwardSpeed") var fastForwardSpeed = 300 { willSet { objectWillChange.send() } }
    @AppStorage("jitMode") private var jitModeRaw = JITMode.auto.rawValue { willSet { objectWillChange.send() } }
    /// Delete a .cia after it was installed from the app's folder (default: keep it in
    /// Games/已安装的 CIA so nothing the user copied in disappears silently).
    @AppStorage("deleteCIAAfterInstall") var deleteCIAAfterInstall = false { willSet { objectWillChange.send() } }
    @AppStorage("jitArenaMB") var jitArenaMB = 384 { willSet { objectWillChange.send() } }
    var jitMode: JITMode {
        get { JITMode(rawValue: jitModeRaw) ?? .auto }
        set { jitModeRaw = newValue.rawValue }
    }

    // MARK: Developer
    @AppStorage("perfOverlay") private var perfOverlayRaw = PerfOverlay.off.rawValue { willSet { objectWillChange.send() } }
    var perfOverlay: PerfOverlay {
        get { PerfOverlay(rawValue: perfOverlayRaw) ?? .off }
        set { perfOverlayRaw = newValue.rawValue }
    }

    // MARK: Layout
    @AppStorage("landscapeLayout") private var landscapeLayoutRaw = ScreenLayout.sideBySide.rawValue { willSet { objectWillChange.send() } }
    @AppStorage("swapScreens") var swapScreens = false { willSet { objectWillChange.send() } }
    var landscapeLayout: ScreenLayout {
        get { ScreenLayout(rawValue: landscapeLayoutRaw) ?? .sideBySide }
        set { landscapeLayoutRaw = newValue.rawValue }
    }

    // MARK: Audio
    @AppStorage("volume") var volume = 1.0 { willSet { objectWillChange.send() } }
    @AppStorage("audioStretching") var audioStretching = true { willSet { objectWillChange.send() } }
    @AppStorage("lleAudio") var lleAudio = false { willSet { objectWillChange.send() } }

    // MARK: System
    @AppStorage("isNew3DS") var isNew3DS = true { willSet { objectWillChange.send() } }
    @AppStorage("region") var region = -1 { willSet { objectWillChange.send() } }
    @AppStorage("lleApplets") var lleApplets = false { willSet { objectWillChange.send() } }

    // MARK: Controls
    @AppStorage("controllerOpacity") var controllerOpacity = 0.75 { willSet { objectWillChange.send() } }
    @AppStorage("haptics") var haptics = true { willSet { objectWillChange.send() } }
    @AppStorage("motionControls") var motionControls = true { willSet { objectWillChange.send() } }
    /// Interpreter compatibility mode: the interpreter without the speed-ups of 2026-10-23/24
    /// (kept translations across core switches, host-FPU VFP, tail-call dispatch, block linking and
    /// return prediction, specialised handlers). For telling whether a game hang comes from them.
    /// Applied when a game starts; no effect while JIT is in use.
    @AppStorage("interpreterCompat") var interpreterCompat = false { willSet { objectWillChange.send() } }
    @AppStorage("hideControllerWithGamepad") var hideControllerWithGamepad = true { willSet { objectWillChange.send() } }

    // MARK: Multiplayer
    @AppStorage("nickname") var nickname = "" { willSet { objectWillChange.send() } }
    @AppStorage("lobbyURL") var lobbyURL = "" { willSet { objectWillChange.send() } }
    @AppStorage("lobbyToken") var lobbyToken = "" { willSet { objectWillChange.send() } }
    @AppStorage("lanDiscovery") var lanDiscovery = true { willSet { objectWillChange.send() } }

    private init() {
        let d = UserDefaults.standard
        // Someone who already picked a CPU clock keeps it instead of the new automatic default.
        // (Saved values only: test launches pass -cpuClock as an argument, which must not count.)
        let saved = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        if saved["cpuClockAuto"] == nil, let manual = saved["cpuClock"] as? Int, manual != 100 {
            cpuClockAuto = false
        }
        // 0.55 was the old default; with the lighter keys it is too faint. Move it up once.
        #if os(visionOS)
        // One-time step down for existing installs: 4× stereo with accurate multiplication made
        // frame pacing erratic on Apple Vision Pro (stalls up to seconds, 40–46 fps).
        if !d.bool(forKey: "visionGfxLowered1") {
            d.set(2, forKey: "resolutionFactor")
            d.set(false, forKey: "accurateMul")
            d.set(0, forKey: "textureFilter")
            d.set(true, forKey: "visionGfxLowered1")
        }
        // One-time stability preset (Super Mario 3D Land freezes): 1× native, synchronous shaders,
        // accurate multiplication, GPU timing simulation, no FXAA, 2D (one eye), 100 % speed.
        if !d.bool(forKey: "visionStability1") {
            d.set(1, forKey: "resolutionFactor")
            d.set(false, forKey: "asyncShaders")
            d.set(true, forKey: "accurateMul")
            d.set(false, forKey: "gpuTimings")
            d.set("off", forKey: "visionAntialiasing")
            d.set(100, forKey: "frameLimit")
            d.set(true, forKey: "visionStability1")
        }
        // GPU timing simulation is experimental upstream (default off since 2026-07) and lines up with
        // the intro/title lost-wakeup hangs in Super Mario 3D Land: force it off once for every install.
        if !d.bool(forKey: "gpuTimingsOff1") {
            d.set(false, forKey: "gpuTimings")
            d.set(true, forKey: "gpuTimingsOff1")
            VisionDiag.log("migration: gpuTimings -> false (gpuTimingsOff1)")
        }
        // The freeze persists with the safe graphics preset: turn the GSP stalled-queue re-signal on once.
        if !d.bool(forKey: "gspResignalOn1") {
            d.set(true, forKey: "gspResignalStalled")
            d.set(true, forKey: "gspResignalOn1")
            VisionDiag.log("migration: gspResignalStalled -> true (gspResignalOn1)")
        }
        // Sharper picture on top of the stability preset: 2x resolution with FXAA, once.
        if !d.bool(forKey: "visionSharp2x1") {
            d.set(2, forKey: "resolutionFactor")
            d.set("fxaa", forKey: "visionAntialiasing")
            d.set(true, forKey: "visionSharp2x1")
            VisionDiag.log("migration: resolutionFactor -> 2, visionAntialiasing -> fxaa (visionSharp2x1)")
        }
        // 4x is back (after the stability and 2x presets): 4x resolution with FXAA, once.
        if !d.bool(forKey: "visionSharp4x1") {
            d.set(4, forKey: "resolutionFactor")
            d.set("fxaa", forKey: "visionAntialiasing")
            d.set(true, forKey: "visionSharp4x1")
            VisionDiag.log("migration: resolutionFactor -> 4, visionAntialiasing -> fxaa (visionSharp4x1)")
        }
        // 5x as the default (Pat, Oct 28): a stored 4x would otherwise win, so set 5 once.
        if !d.bool(forKey: "visionSharp5x1") {
            d.set(5, forKey: "resolutionFactor")
            d.set(true, forKey: "visionSharp5x1")
            VisionDiag.log("migration: resolutionFactor -> 5 (visionSharp5x1)")
        }
        // A CPU clock below 100 % hung Super Mario 3D Land loading levels: back to auto (100 %), once.
        if !d.bool(forKey: "cpuClock100v1") {
            let before = d.object(forKey: "cpuClock") as? Int ?? 100
            d.set(true, forKey: "cpuClockAuto")
            if before < 100 { d.set(100, forKey: "cpuClock") }
            d.set(true, forKey: "cpuClock100v1")
            VisionDiag.log("migration: cpuClockAuto -> true, cpuClock \(before) -> \(max(before, 100)) (cpuClock100v1)")
        }
        if !d.bool(forKey: "visionDefault2D1") {
            d.set(0, forKey: "visionStereoDepth")
            d.set(true, forKey: "visionDefault2D1")
        }
        // Stereo is the default again: move every install to a full 3D slider once.
        if !d.bool(forKey: "visionDefault3D1") {
            d.set(100, forKey: "visionStereoDepth")
            d.set(true, forKey: "visionDefault3D1")
        }
        #endif
        if !d.bool(forKey: "controllerOpacityMigrated") {
            if d.object(forKey: "controllerOpacity") != nil, abs(controllerOpacity - 0.55) < 0.001 { controllerOpacity = 0.75 }
            d.set(true, forKey: "controllerOpacityMigrated")
        }
        if nickname.isEmpty {
            nickname = "iOS-" + String(UUID().uuidString.prefix(4))
        }
        if lobbyToken.isEmpty {
            // Open lobbies accept any non-empty token; a random one identifies this device.
            lobbyToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    }

    /// Writes the emulator part of the settings for the core.
    func writeCoreConfig(to userDirectory: URL) {
        #if APPSTORE
        let allowJIT = false
        #else
        let allowJIT = true
        #endif
        #if os(visionOS)
        // Texture filters + custom textures render black on Vulkan/MoltenVK (azahar #2354), and
        // No switch for it in the app: always off, whatever an earlier build stored.
        let coreTextureFilter = 0
        #else
        let coreTextureFilter = textureFilter
        #endif
        let ini = """
        ; Written by the 3DS_iOS app. Edit settings in the app instead of here.
        [Core]
        use_cpu_jit = \(allowJIT)
        cpu_clock_percentage = \(effectiveCPUClock)

        [Renderer]
        graphics_api = 2
        use_hw_shader = true
        shaders_accurate_mul = \(accurateMul)
        use_disk_shader_cache = \(diskShaderCache)
        async_shader_compilation = \(asyncShaders)
        async_presentation = true
        simulate_3ds_gpu_timings = \(gpuTimings)
        apple_pipeline_fast_path = \(vkPipelineFastPath)
        apple_skip_unready_small_draws = \(vkSkipUnreadyDraws)
        apple_async_queue_submits = \(vkAsyncQueueSubmits)
        apple_gsp_resignal_stalled = \(gspResignalStalled)
        spirv_shader_gen = true
        resolution_factor = \(resolutionFactor)
        frame_limit = \(frameLimit)
        use_vsync = \(vsync)
        texture_filter = \(coreTextureFilter)
        texture_sampling = \(textureSampling)
        filter_mode = \(linearFiltering)

        [Layout]
        layout_option = \(landscapeLayout.coreValue)
        portrait_layout_option = 0
        swap_screen = \(swapScreens)

        [Audio]
        audio_emulation = \(lleAudio ? 1 : 0)
        enable_audio_stretching = \(audioStretching)
        volume = \(volume)
        output_type = 0
        input_type = 1

        [System]
        is_new_3ds = \(isNew3DS)
        lle_applets = \(lleApplets)
        region_value = \(region)

        [Data Storage]
        use_virtual_sd = true

        [WebService]
        web_api_url = \(lobbyURL)
        network_token = \(lobbyToken)

        [Utility]
        custom_textures = \(customTextures)
        preload_textures = \(preloadTextures)
        async_custom_loading = true

        [Miscellaneous]
        log_filter = *:Info

        """
        let url = userDirectory.appendingPathComponent("config/ios-config.ini")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ini.write(to: url, atomically: true, encoding: .utf8)
    }
}

#if os(visionOS)
import os

/// The default internal resolution from the memory the app may still use, measured once at launch.
/// Conservative thresholds (Apple does not document the limits); vision-diag.log records both
/// numbers so they can be tuned from real devices.
enum VisionMemoryBudget {
    static let availableBytes: UInt64 = UInt64(os_proc_available_memory())

    static let resolutionFactor: Int = {
        // 0 = not reported (the Simulator always says 0): take the middle step.
        guard availableBytes > 0 else { return 3 }
        let gib = Double(availableBytes) / 1_073_741_824
        // 4×/3× stereo made frame pacing erratic on the device (40–46 fps, multi-second stalls);
        // 2× held 60 fps.
        return gib >= 3.0 ? 5 : 1   // 5x default with the Increased Memory Limit
    }()
}
#endif
