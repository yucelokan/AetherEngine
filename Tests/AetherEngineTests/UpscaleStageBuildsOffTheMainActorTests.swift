#if !targetEnvironment(simulator)
import Foundation
import Synchronization
import Testing
import CoreMedia
import CoreVideo
import Metal
@testable import AetherEngine

private enum StageGate {
    static var gpuAvailable: Bool {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }
}

private let plan = UpscalePlan(
    sourceWidth: 1280, sourceHeight: 720, mlScale: nil, mlOutputWidth: 1280, mlOutputHeight: 720,
    targetWidth: 1920, targetHeight: 1080, displayWidth: 1920, displayHeight: 1080)

private func frame() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                     kCVPixelBufferMetalCompatibilityKey as String: true]
    CVPixelBufferCreate(nil, plan.sourceWidth, plan.sourceHeight, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        attributes as CFDictionary, &buffer)
    return try #require(buffer)
}

/// The software host's load runs on the main actor, and building the stage compiles Metal kernels and starts
/// MetalFX and VideoToolbox: none of that may happen there, and no frame may wait for it (#846).
@Suite("Upscale stage builds off the main actor", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: StageGate.gpuAvailable))
struct UpscaleStageBuildsOffTheMainActorTests {

    @MainActor
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    @Test func theBuildLeavesTheMainActorAndFramesPassThroughUntilItIsDone() async throws {
        let release = DispatchSemaphore(value: 0)
        let builtOnMain = Mutex<Bool?>(nil)
        let upscaler = DeferredFrameUpscaler {
            builtOnMain.withLock { $0 = Thread.isMainThread }
            release.wait()
            return FrameUpscaler(plan: plan, frameInterval: 1.0 / 24)
        }
        defer { release.signal() }
        let input = try frame()

        try await waitFor { builtOnMain.withLock { $0 } != nil }
        #expect(builtOnMain.withLock { $0 } == false)
        #expect(!upscaler.isReady)
        #expect(upscaler.upscale(input, pts: .zero) == nil)

        release.signal()
        try await waitFor { upscaler.isReady }
        let output = try #require(upscaler.upscale(input, pts: .zero))
        #expect(CVPixelBufferGetWidth(output) == plan.targetWidth && CVPixelBufferGetHeight(output) == plan.targetHeight)
    }

    @MainActor
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    @Test func anEventHandlerSetBeforeTheStageExistsReachesIt() async throws {
        let release = DispatchSemaphore(value: 0)
        let upscaler = DeferredFrameUpscaler {
            release.wait()
            return FrameUpscaler(plan: plan, frameInterval: 1.0 / 24)
        }
        defer { release.signal() }
        let firstFrames = Mutex(0)
        upscaler.onEvent = { event in
            if case .firstFrame = event { firstFrames.withLock { $0 += 1 } }
        }
        #expect(upscaler.delivered == nil)

        release.signal()
        try await waitFor { upscaler.isReady }
        _ = upscaler.upscale(try frame(), pts: .zero)
        #expect(firstFrames.withLock { $0 } == 1)
        #expect(upscaler.delivered?.plan == plan)
    }

    @MainActor
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    @Test func aStageThatCannotBeBuiltLeavesFramesAsDecoded() async throws {
        let attempted = Mutex(false)
        let upscaler = DeferredFrameUpscaler {
            attempted.withLock { $0 = true }
            return nil
        }
        try await waitFor { attempted.withLock { $0 } }
        #expect(upscaler.upscale(try frame(), pts: .zero) == nil)
        #expect(!upscaler.isReady)
        #expect(upscaler.disabledReason == nil)
    }

    @MainActor
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    @Test func theHostsHandlerRunsTheStageOnceItIsBuilt() async throws {
        let host = SoftwarePlaybackHost()
        host.upscalePlan = plan
        let delivered = Mutex<(Int, Int)?>(nil)
        let handler = host.upscaledFrameHandler({ buffer, _, _ in
            delivered.withLock { $0 = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)) }
        }, decoder: SoftwareVideoDecoder(), frameRate: 24)
        let upscaler = try #require(host.frameUpscaler as? DeferredFrameUpscaler)

        try await waitFor { upscaler.isReady }
        handler(try frame(), .zero, nil)
        #expect(delivered.withLock { $0 }.map { [$0.0, $0.1] } == [plan.targetWidth, plan.targetHeight])
    }
}
#endif
