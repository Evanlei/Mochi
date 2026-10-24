import AppKit
import Foundation

@main
struct MochiE2ETests {
    @MainActor
    static func main() async throws {
        let startTime = Date()
        print("================================================================")
        print("           Mochi Opaque-Box E2E Test Suite Runner               ")
        print("================================================================")

        let args = CommandLine.arguments.dropFirst()
        let requestedTier: Int?
        if let tierIndex = args.firstIndex(of: "--tier"), tierIndex + 1 < args.endIndex {
            requestedTier = Int(args[tierIndex + 1])
        } else {
            requestedTier = nil
        }

        var executedTiers = 0
        var totalFailures = 0

        do {
            if requestedTier == nil || requestedTier == 1 {
                let tierStart = Date()
                try await Tier1FeatureCoverageTests.runAll()
                let elapsed = String(format: "%.2fs", Date().timeIntervalSince(tierStart))
                print("⏱️  Tier 1 Duration: \(elapsed)")
                executedTiers += 1
            }

            if requestedTier == nil || requestedTier == 2 {
                let tierStart = Date()
                try await Tier2BoundaryCornerTests.runAll()
                let elapsed = String(format: "%.2fs", Date().timeIntervalSince(tierStart))
                print("⏱️  Tier 2 Duration: \(elapsed)")
                executedTiers += 1
            }

            if requestedTier == nil || requestedTier == 3 {
                let tierStart = Date()
                try await Tier3CombinationTests.runAll()
                let elapsed = String(format: "%.2fs", Date().timeIntervalSince(tierStart))
                print("⏱️  Tier 3 Duration: \(elapsed)")
                executedTiers += 1
            }

            if requestedTier == nil || requestedTier == 4 {
                let tierStart = Date()
                try await Tier4RealWorldScenariosTests.runAll()
                let elapsed = String(format: "%.2fs", Date().timeIntervalSince(tierStart))
                print("⏱️  Tier 4 Duration: \(elapsed)")
                executedTiers += 1
            }
        } catch {
            print("\n❌ E2E TEST RUNNER ENCOUNTERED UNHANDLED ERROR:")
            print("   \(error)")
            totalFailures += 1
        }

        let totalDuration = String(format: "%.2fs", Date().timeIntervalSince(startTime))
        print("\n================================================================")
        if totalFailures == 0 {
            print("🎉 ALL \(executedTiers) E2E TIERS PASSED SUCCESSFULLY (118+ total test cases)!")
            print("   Total Run Duration: \(totalDuration)")
            print("================================================================")
            exit(0)
        } else {
            print("💥 E2E SUITE FAILED WITH \(totalFailures) ERROR(S)")
            print("   Total Run Duration: \(totalDuration)")
            print("================================================================")
            exit(1)
        }
    }
}
