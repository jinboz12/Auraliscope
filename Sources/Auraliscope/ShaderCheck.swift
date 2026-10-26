import Foundation
import Metal

/// `--check-shaders`: compiles the canvases' Metal library and builds every pipeline state, headless, with no window
/// and no frame drawn. Launch builds the same pipelines, so a broken shader or a struct that no longer matches its
/// shader declaration (`MeterGPU.layoutChecks`) is otherwise found only when the app starts. This checks compilation
/// and layout, not what the shaders draw: that is the GPU rendering self-tests (`--test-nebula-gpu`, `--render-preview`).
enum ShaderCheck {
    /// 0 when everything compiled, 1 when something did not, 77 when this machine has no Metal device.
    static func run() -> Int32 {
        guard MTLCreateSystemDefaultDevice() != nil else {
            print("SKIP: no Metal device, so the shaders were not compiled")
            return 77
        }
        let started = Date()
        switch MeterGPU.shared {
        case .success:
            print(String(format: "PASS: shader library compiled and every pipeline state built (%.0f ms)", Date().timeIntervalSince(started) * 1000))
            return 0
        case .failure(let error):
            print("FAIL: \(error)")
            return 1
        }
    }
}
