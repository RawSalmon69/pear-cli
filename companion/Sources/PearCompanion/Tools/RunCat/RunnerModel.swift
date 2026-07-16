import AppKit
import Foundation
import Observation

// A RunCat-style animated runner for the menu bar: a little cat that ambles
// when the Mac is idle and sprints when the CPU is pegged. The animation logic
// (frame cadence as a function of CPU load) is adapted from RunCat365
// (Apache-2.0) — https://github.com/runcat-dev/RunCat365 — specifically its
// `Program.CalculateInterval`. We draw our own frames (see RunnerFrames) and
// take no dependency on RunCat.

/// Pure CPU-load → frame-interval mapping. Kept free of any state or actor so
/// it is trivially unit-testable without hardware.
///
/// Adapted from RunCat365 (Apache-2.0): RunCat computes
/// `speed = max(1, load% / 5)` then `interval = 500ms / speed`, so the interval
/// starts flat at idle and shrinks hyperbolically as load rises. We keep that
/// shape — interval is `base / speed`, `speed` linear in load — but retune the
/// endpoints to a menu-bar-friendly range instead of RunCat's 500…25 ms.
enum RunnerCadence {
    /// Seconds per frame at 0% CPU — a slow amble.
    static let idleInterval: Double = 0.200
    /// Seconds per frame at 100% CPU — a fast run. Also the hard floor: the
    /// timer can never tick faster than this.
    static let peggedInterval: Double = 0.040

    /// Maps a whole-machine CPU busy fraction (0…1) to a per-frame interval in
    /// seconds. The input is clamped, so a bogus or out-of-range sample can
    /// never run the timer away or stall it: the result always lands in
    /// `[peggedInterval, idleInterval]`. Monotonically non-increasing in load.
    static func frameInterval(cpuFraction: Double) -> Double {
        let load = min(1, max(0, cpuFraction))
        // speed = 1 at idle, rising linearly to idle/pegged (= 5) when pegged.
        let speed = 1 + load * (idleInterval / peggedInterval - 1)
        return idleInterval / speed
    }
}

/// Owns the previous CPU tick sample behind an actor so the raw Mach call and
/// the diff run off the main actor. Being an actor makes it `Sendable`; only
/// the resulting `Double` (a busy fraction) ever crosses back to the model.
/// No shared mutable state escapes, so no `@unchecked` is needed.
actor RunnerCPUSampler {
    private var prevTicks: [UInt32]?

    /// Whole-machine CPU busy fraction (0…1) since the previous call, or nil on
    /// the first call (no baseline yet) or if the host call fails. Mirrors the
    /// Monitor tool's two-tick delta, averaged across cores.
    func sampleTotal() -> Double? {
        guard let ticks = CPUSampler.readTicks() else { return nil }
        defer { prevTicks = ticks }
        guard let prev = prevTicks, prev.count == ticks.count else { return nil }
        let usages = CPUUsage.coreUsages(previous: prev, current: ticks)
        guard !usages.isEmpty else { return nil }
        return usages.reduce(0, +) / Double(usages.count)
    }
}

/// Main-actor observable that drives the menu-bar runner. The menu-bar label
/// renders `currentFrame`; the app flips `isEnabled` and calls `start()`.
///
/// Two cooperating tasks run only while enabled and started: a ~2 s CPU sampler
/// that sets the current cadence, and an animation loop that advances the frame
/// and sleeps for that cadence. Both are cancelled on `stop()` / `deinit`, so
/// the feature costs 0% when off — there is deliberately no timer at rest.
@MainActor
@Observable
final class RunnerModel {
    /// The frame the menu-bar label should draw right now. Stable image when
    /// stopped (the first frame), so a disabled runner shows a still cat.
    private(set) var currentFrame: NSImage

    /// Whether the runner is on. Persisted; toggling it starts/stops the loops.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: defaultsKey)
            if isEnabled { start() } else { stop() }
        }
    }

    @ObservationIgnored private let frames: [NSImage]
    @ObservationIgnored private var frameIndex = 0
    /// The live per-frame interval, updated by the CPU sampler and read by the
    /// animation loop each tick. Starts at the idle amble.
    @ObservationIgnored private var interval = RunnerCadence.idleInterval

    @ObservationIgnored private let sampler = RunnerCPUSampler()
    @ObservationIgnored private var animateTask: Task<Void, Never>?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultsKey: String

    /// - Parameters:
    ///   - defaults: injectable so tests don't touch the shared domain.
    ///   - defaultsKey: injectable persistence key. Default off — opt-in.
    init(defaults: UserDefaults = .standard, defaultsKey: String = "runnerEnabled") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.isEnabled = defaults.bool(forKey: defaultsKey)
        self.frames = RunnerFrames.frames()
        self.currentFrame = frames.first ?? NSImage(size: RunnerFrames.size)
    }

    /// Starts sampling + animating if enabled. Idempotent — a second call while
    /// already running is a no-op, so `.onAppear`/launch can call it freely.
    func start() {
        guard isEnabled, animateTask == nil else { return }
        frameIndex = 0
        interval = RunnerCadence.idleInterval
        currentFrame = frames[frameIndex]
        startSampling()
        startAnimating()
    }

    /// Stops both loops and parks on the first frame. Called on disable/deinit.
    func stop() {
        animateTask?.cancel()
        animateTask = nil
        sampleTask?.cancel()
        sampleTask = nil
        frameIndex = 0
        currentFrame = frames[frameIndex]
    }

    private func startSampling() {
        sampleTask = Task { [weak self, sampler] in
            // Seed the baseline, wait briefly, then take the first real reading
            // so the cadence reacts within a second instead of a full interval.
            _ = await sampler.sampleTotal()
            try? await Task.sleep(for: .milliseconds(600))
            while !Task.isCancelled {
                let total = await sampler.sampleTotal()
                guard let self, !Task.isCancelled else { return }
                if let total { self.interval = RunnerCadence.frameInterval(cpuFraction: total) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startAnimating() {
        animateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !Task.isCancelled else { return }
                self.advance()
                let wait = self.interval
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func advance() {
        frameIndex = (frameIndex + 1) % frames.count
        currentFrame = frames[frameIndex]
    }

    deinit {
        animateTask?.cancel()
        sampleTask?.cancel()
    }
}
