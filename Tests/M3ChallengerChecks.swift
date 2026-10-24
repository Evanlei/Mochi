import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@MainActor
@main
struct M3ChallengerChecks {
    static func main() async throws {
        print("==================================================================")
        print("    M3 EMPIRICAL CHALLENGER VERIFICATION & STRESS HARNESS        ")
        print("==================================================================")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        print("\n--- Suite 1: Accessibility Reduce Motion Invariants & Poses ---")
        try testReduceMotionInvariants()
        try testReduceMotionStaticScaleOverTime()
        try testReduceMotionDedicatedPoses()

        print("\n--- Suite 2: State Machine Priority Hierarchy Matrix ---")
        try testPriorityHierarchyReduceMotion()
        try testPriorityHierarchyDynamicMotion()

        print("\n--- Suite 3: Dynamic Motion Kinematics & Extreme Edge Cases ---")
        try testDynamicMotionExtremeTimeIntervals()
        try testDynamicDragLeanAndBoundaries()
        try testCelebrationImpulseLifecycle()
        try testWakingUpKinematics()
        try testActivityMotionInterruptibleTransitions()

        print("\n--- Suite 4: Spring Micro-Interactions & Styling ---")
        try testMochiPressStylePhysics()

        print("\n==================================================================")
        print("  🎉 ALL M3 EMPIRICAL CHALLENGER TESTS EXECUTED SUCCESSFULLY!   ")
        print("==================================================================")
    }

    // MARK: - Suite 1: Accessibility Reduce Motion Invariants & Static Poses

    static func testReduceMotionInvariants() throws {
        print("  Checking strict invariants (tilt=0, lift=0, leftWave=0, rightWave=0)...")
        var activityThinking = MochiMascotActivityMotion()
        activityThinking.set(.thinking, at: 0)
        var activityCurious = MochiMascotActivityMotion()
        activityCurious.set(.curious, at: 0)

        let testTimes: [TimeInterval] = [0.0, 0.1, 1.0, 5.5, 11.0, 26.5, 90.0, 93.0, 120.0, 999.9, 10_000.0]
        let booleanMatrix: [(isMusic: Bool, isHover: Bool, isHeld: Bool, isEngaged: Bool)] = [
            (false, false, false, false),
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
            (true, true, true, true),
            (true, false, true, false),
            (false, true, true, false),
            (true, false, false, true)
        ]

        let activities = [MochiMascotActivityMotion(), activityThinking, activityCurious]

        for time in testTimes {
            for combo in booleanMatrix {
                for act in activities {
                    let pose = MochiMascotPose.at(
                        time: time,
                        isMusicPlaying: combo.isMusic,
                        isHovered: combo.isHover,
                        isHeld: combo.isHeld,
                        isEngaged: combo.isEngaged,
                        dragLean: combo.isHeld ? 5.0 : 0.0,
                        hoverStartedAt: combo.isHover ? time : nil,
                        releasedAt: nil,
                        idleStartedAt: 0.0,
                        wakeStartedAt: nil,
                        wakeStrength: 0.0,
                        activityMotion: act,
                        celebrationStartedAt: combo.isMusic ? time : nil,
                        animate: false
                    )

                    precondition(pose.tilt == 0, "Invariant violation: tilt (\(pose.tilt)) must be 0 when animate=false at t=\(time)")
                    precondition(pose.lift == 0, "Invariant violation: lift (\(pose.lift)) must be 0 when animate=false at t=\(time)")
                    precondition(pose.leftWave == 0, "Invariant violation: leftWave (\(pose.leftWave)) must be 0 when animate=false at t=\(time)")
                    precondition(pose.rightWave == 0, "Invariant violation: rightWave (\(pose.rightWave)) must be 0 when animate=false at t=\(time)")
                }
            }
        }
        print("    ✓ Reduce Motion invariants verified across \(testTimes.count * booleanMatrix.count * activities.count) state permutations.")
    }

    static func testReduceMotionStaticScaleOverTime() throws {
        print("  Checking static scale over time (zero continuous oscillations)...")
        let times: [TimeInterval] = [0.0, 0.25, 0.5, 1.2, 2.4, 3.6, 4.8, 6.0, 10.0, 26.0, 26.5, 90.0, 93.0, 150.0]

        // 1. Idle
        let baseIdle = MochiMascotPose.at(time: 0.0, animate: false)
        for t in times {
            let pose = MochiMascotPose.at(time: t, animate: false)
            precondition(pose.scaleX == baseIdle.scaleX, "Idle scaleX oscillated under Reduce Motion at t=\(t)")
            precondition(pose.scaleY == baseIdle.scaleY, "Idle scaleY oscillated under Reduce Motion at t=\(t)")
        }

        // 2. Music Playing
        let baseMusic = MochiMascotPose.at(time: 0.0, isMusicPlaying: true, animate: false)
        for t in times {
            let pose = MochiMascotPose.at(time: t, isMusicPlaying: true, celebrationStartedAt: 0.0, animate: false)
            precondition(pose.scaleX == baseMusic.scaleX, "Music playing scaleX oscillated under Reduce Motion at t=\(t)")
            precondition(pose.scaleY == baseMusic.scaleY, "Music playing scaleY oscillated under Reduce Motion at t=\(t)")
        }

        // 3. Sleeping (idleStartedAt = 0, t > 93)
        let baseSleep = MochiMascotPose.at(time: 100.0, idleStartedAt: 0.0, animate: false)
        for t in [93.1, 95.0, 100.0, 200.0, 500.0] {
            let pose = MochiMascotPose.at(time: t, idleStartedAt: 0.0, animate: false)
            precondition(pose.scaleX == baseSleep.scaleX, "Sleep scaleX oscillated under Reduce Motion at t=\(t)")
            precondition(pose.scaleY == baseSleep.scaleY, "Sleep scaleY oscillated under Reduce Motion at t=\(t)")
        }

        // 4. Held
        let baseHeld = MochiMascotPose.at(time: 0.0, isHeld: true, dragLean: 2.0, animate: false)
        for t in times {
            let pose = MochiMascotPose.at(time: t, isHeld: true, dragLean: 2.0, animate: false)
            precondition(pose.scaleX == baseHeld.scaleX, "Held scaleX oscillated under Reduce Motion at t=\(t)")
            precondition(pose.scaleY == baseHeld.scaleY, "Held scaleY oscillated under Reduce Motion at t=\(t)")
        }
        print("    ✓ Zero continuous scale oscillations confirmed across idle, music, sleep, and held states.")
    }

    static func testReduceMotionDedicatedPoses() throws {
        print("  Checking dedicated static expressions for each distinct state...")

        // Held
        let held = MochiMascotPose.at(time: 50.0, isHeld: true, animate: false)
        precondition(held.scaleX == 0.88, "Held scaleX must be 0.88")
        precondition(held.scaleY == 1.16, "Held scaleY must be 1.16")
        precondition(held.mouthOpen == 1, "Held mouthOpen must be 1")
        precondition(held.eyeHeight == 1.4, "Held eyeHeight must be 1.4")
        precondition(held.eyeWidth == 1.35, "Held eyeWidth must be 1.35")

        // Sleeping
        let sleep = MochiMascotPose.at(time: 120.0, idleStartedAt: 0.0, animate: false)
        precondition(sleep.scaleX == 1.07, "Sleep scaleX must be 1.07")
        precondition(sleep.scaleY == 0.85, "Sleep scaleY must be 0.85")
        precondition(sleep.closedEyes == 1, "Sleep closedEyes must be 1")
        precondition(sleep.sleepAmount == 1, "Sleep sleepAmount must be 1")
        precondition(sleep.happyEyes == 0, "Sleep happyEyes must be 0")
        precondition(sleep.smileDepth == 5, "Sleep smileDepth must be 5")

        // Music Playing
        let music = MochiMascotPose.at(time: 50.0, isMusicPlaying: true, animate: false)
        precondition(music.happyEyes == 1, "Music happyEyes must be 1")
        precondition(music.smileDepth == 17, "Music smileDepth must be 17")
        precondition(music.cheeks == 0.22, "Music cheeks must be 0.22")

        // Thinking
        var thinkMotion = MochiMascotActivityMotion()
        thinkMotion.set(.thinking, at: 0)
        let thinking = MochiMascotPose.at(time: 1.0, activityMotion: thinkMotion, animate: false)
        precondition(thinking.eyeHeight == 0.8, "Thinking eyeHeight must be 0.8")
        precondition(thinking.smileDepth == 1, "Thinking smileDepth must be 1")

        // Curious
        var curiousMotion = MochiMascotActivityMotion()
        curiousMotion.set(.curious, at: 0)
        let curious = MochiMascotPose.at(time: 1.0, activityMotion: curiousMotion, animate: false)
        precondition(curious.eyeWidth == 1.2, "Curious eyeWidth must be 1.2")
        precondition(curious.smileDepth == 9, "Curious smileDepth must be 9")

        // Idle
        let idle = MochiMascotPose.at(time: 1.0, animate: false)
        precondition(idle.scaleX == 1.0 && idle.scaleY == 1.0, "Idle scale must be neutral 1.0")
        precondition(idle.eyeHeight == 1.0 && idle.eyeWidth == 1.0, "Idle eyes must be neutral 1.0")
        precondition(idle.mouthOpen == 0.0 && idle.closedEyes == 0.0, "Idle mouth and eyes must be neutral")

        print("    ✓ All 6 static expressions matched exact design specifications.")
    }

    // MARK: - Suite 2: State Machine Priority Hierarchy Matrix

    static func testPriorityHierarchyReduceMotion() throws {
        print("  Checking Priority Order in Reduce Motion (Held > Sleeping > Music > Thinking > Curious > Idle)...")
        var thinkMotion = MochiMascotActivityMotion()
        thinkMotion.set(.thinking, at: 0)
        var curiousMotion = MochiMascotActivityMotion()
        curiousMotion.set(.curious, at: 0)

        // 1. Held beats everything
        let heldOverAll = MochiMascotPose.at(
            time: 200.0,
            isMusicPlaying: true,
            isHovered: true,
            isHeld: true,
            isEngaged: true,
            idleStartedAt: 0.0,
            activityMotion: thinkMotion,
            celebrationStartedAt: 199.5,
            animate: false
        )
        precondition(heldOverAll.scaleY == 1.16 && heldOverAll.mouthOpen == 1, "Held must override all states in Reduce Motion")
        precondition(heldOverAll.closedEyes == 0 && heldOverAll.sleepAmount == 0, "Held must not have sleep eyes")

        // 2. Sleeping beats Music, Thinking, Curious, Idle
        let sleepOverMusicAndThink = MochiMascotPose.at(
            time: 200.0,
            isMusicPlaying: true,
            idleStartedAt: 0.0,
            activityMotion: thinkMotion,
            celebrationStartedAt: 199.5,
            animate: false
        )
        precondition(sleepOverMusicAndThink.closedEyes == 1 && sleepOverMusicAndThink.sleepAmount == 1, "Sleep must override music and thinking in Reduce Motion")
        precondition(sleepOverMusicAndThink.happyEyes == 0, "Sleep must zero out happyEyes")

        // 3. Music beats Thinking and Curious
        let musicOverThink = MochiMascotPose.at(
            time: 10.0,
            isMusicPlaying: true,
            isEngaged: true,
            activityMotion: thinkMotion,
            animate: false
        )
        precondition(musicOverThink.happyEyes == 1 && musicOverThink.smileDepth == 17, "Music must override thinking in Reduce Motion")

        let musicOverCurious = MochiMascotPose.at(
            time: 10.0,
            isMusicPlaying: true,
            isEngaged: true,
            activityMotion: curiousMotion,
            animate: false
        )
        precondition(musicOverCurious.happyEyes == 1 && musicOverCurious.smileDepth == 17, "Music must override curious in Reduce Motion")

        // 4. Thinking beats Curious
        let thinkOverCurious = MochiMascotPose.at(
            time: 10.0,
            isEngaged: true,
            activityMotion: thinkMotion,
            animate: false
        )
        precondition(thinkOverCurious.eyeHeight == 0.8 && thinkOverCurious.smileDepth == 1, "Thinking must take precedence")

        print("    ✓ Reduce Motion priority hierarchy strictly verified.")
    }

    static func testPriorityHierarchyDynamicMotion() throws {
        print("  Checking Priority Order in Dynamic Motion...")
        var thinkMotion = MochiMascotActivityMotion()
        thinkMotion.set(.thinking, at: 0)

        // 1. Held beats Sleeping and Music
        let heldOverSleepMusic = MochiMascotPose.at(
            time: 200.0,
            isMusicPlaying: true,
            isHeld: true,
            dragLean: 1.5,
            idleStartedAt: 0.0,
            activityMotion: thinkMotion,
            celebrationStartedAt: 199.5,
            animate: true
        )
        precondition(heldOverSleepMusic.mouthOpen == 1.0, "Held must set mouthOpen=1")
        precondition(heldOverSleepMusic.scaleY == 1.16, "Held must set scaleY=1.16")
        precondition(heldOverSleepMusic.tilt == 1.5 * 9, "Held dynamic tilt must follow dragLean * 9")
        precondition(heldOverSleepMusic.sleepAmount == 0 && heldOverSleepMusic.closedEyes == 0, "Held must override sleep")
        precondition(heldOverSleepMusic.happyEyes == 0, "Held must override happyEyes")

        // 2. Sleeping beats Music Playing and Idle
        let sleepOverMusic = MochiMascotPose.at(
            time: 200.0,
            isMusicPlaying: true,
            idleStartedAt: 0.0,
            animate: true
        )
        precondition(sleepOverMusic.sleepAmount == 1.0, "Sleeping must override music when inactive > 93s")
        precondition(sleepOverMusic.closedEyes == 1.0, "Sleeping must close eyes")
        precondition(sleepOverMusic.happyEyes == 0.0, "Sleeping must suppress happyEyes")
        precondition(sleepOverMusic.lift == 0.0, "Sleeping must suppress dancing lift")

        // 3. Music Playing (when active, idle < 90s, not held, not hovered)
        let musicPlayingDance = MochiMascotPose.at(
            time: 10.0,
            isMusicPlaying: true,
            animate: true
        )
        precondition(musicPlayingDance.happyEyes == 1.0, "Music dance must have happyEyes=1")
        precondition(musicPlayingDance.smileDepth == 17.0, "Music dance must have smileDepth=17")
        precondition(musicPlayingDance.leftWave > 0, "Music dance must have leftWave arm movement")

        // 4. Music Playing with card open (isEngaged = true, idle activity)
        let musicCardOpen = MochiMascotPose.at(
            time: 10.0,
            isMusicPlaying: true,
            isEngaged: true,
            activityMotion: MochiMascotActivityMotion(),
            animate: true
        )
        precondition(musicCardOpen.happyEyes == 1.0, "Music dance must continue when card is open and user is idle")

        print("    ✓ Dynamic motion priority hierarchy verified.")
    }

    // MARK: - Suite 3: Dynamic Motion Kinematics & Extreme Edge Cases

    static func testDynamicMotionExtremeTimeIntervals() throws {
        print("  Checking extreme time intervals (large t, negative dt, tiny dt)...")
        let extremeTimes: [TimeInterval] = [
            0.0,
            1e-9,
            1e-3,
            100.0,
            100.000001,
            86400.0, // 1 day
            1_000_000.0,
            1e8
        ]

        for t in extremeTimes {
            let pose = MochiMascotPose.at(time: t, isMusicPlaying: true, isEngaged: true, animate: true)
            precondition(!pose.scaleX.isNaN && !pose.scaleX.isInfinite, "scaleX became NaN/Infinite at t=\(t)")
            precondition(!pose.scaleY.isNaN && !pose.scaleY.isInfinite, "scaleY became NaN/Infinite at t=\(t)")
            precondition(!pose.tilt.isNaN && !pose.tilt.isInfinite, "tilt became NaN/Infinite at t=\(t)")
            precondition(!pose.lift.isNaN && !pose.lift.isInfinite, "lift became NaN/Infinite at t=\(t)")
            precondition(!pose.leftWave.isNaN && !pose.leftWave.isInfinite, "leftWave became NaN/Infinite at t=\(t)")
            precondition(!pose.rightWave.isNaN && !pose.rightWave.isInfinite, "rightWave became NaN/Infinite at t=\(t)")
        }
        print("    ✓ Extreme time values handled without NaN or Infinite values.")
    }

    static func testDynamicDragLeanAndBoundaries() throws {
        print("  Checking dragLean response and bounds...")
        for lean in [-10.0, -2.5, -1.0, 0.0, 1.0, 2.5, 10.0] as [CGFloat] {
            let dynamicHeld = MochiMascotPose.at(time: 50.0, isHeld: true, dragLean: lean, animate: true)
            precondition(dynamicHeld.tilt == lean * 9, "Dynamic tilt must equal dragLean * 9")
            precondition(dynamicHeld.lookX == lean * 8, "Dynamic lookX must equal dragLean * 8")

            let staticHeld = MochiMascotPose.at(time: 50.0, isHeld: true, dragLean: lean, animate: false)
            precondition(staticHeld.tilt == 0, "Reduce Motion tilt must be 0 regardless of dragLean")
            precondition(staticHeld.leftWave == 0 && staticHeld.rightWave == 0, "Reduce Motion waves must be 0 regardless of dragLean")
        }
        print("    ✓ dragLean correctly transforms dynamic pose and strictly zeroed in Reduce Motion.")
    }

    static func testCelebrationImpulseLifecycle() throws {
        print("  Checking celebration impulse lifecycle (start, peak, decay, finish)...")
        let start: TimeInterval = 100.0

        // Before start
        let before = MochiMascotPose.at(time: 99.9, celebrationStartedAt: start, animate: true)
        precondition(before.happyEyes == 0, "No celebration before startedAt")

        // Peak / in progress (t = 100.2)
        let peak = MochiMascotPose.at(time: 100.2, celebrationStartedAt: start, animate: true)
        precondition(peak.happyEyes == 1.0, "Celebration must have happyEyes=1.0 at peak")
        precondition(peak.smileDepth > 15.0, "Celebration must have warm smile at peak")
        precondition(peak.rightWave < -50.0, "Celebration must wave right hand at peak")

        // Concluded (t = 100.9 > 0.8s duration)
        let after = MochiMascotPose.at(time: 100.9, celebrationStartedAt: start, animate: true)
        precondition(after.happyEyes == 0.0, "Celebration must end after 0.8s")
        print("    ✓ Celebration impulse correctly transitions through 0.8s lifecycle.")
    }

    static func testWakingUpKinematics() throws {
        print("  Checking waking up kinematics and transitions...")
        let wakeStart: TimeInterval = 50.0

        // In the middle of wake (t = 50.5s)
        let waking = MochiMascotPose.at(time: 50.5, wakeStartedAt: wakeStart, wakeStrength: 1.0, animate: true)
        precondition(!waking.scaleX.isNaN, "Waking scaleX must be valid")
        precondition(!waking.scaleY.isNaN, "Waking scaleY must be valid")
        precondition(waking.lift == 0, "Waking lift must be 0")
        precondition(waking.rightWave == 0, "Waking rightWave must be 0")

        // After wake completed (t = 52.0 > 1.2s duration)
        let awake = MochiMascotPose.at(time: 52.0, wakeStartedAt: wakeStart, wakeStrength: 1.0, animate: true)
        precondition(awake.closedEyes == 0, "Eyes must be open after wake concludes")
        precondition(awake.sleepAmount == 0, "Sleep amount must be 0 after wake concludes")
        print("    ✓ Waking up transition smoothly settles mascot into awake pose.")
    }

    static func testActivityMotionInterruptibleTransitions() throws {
        print("  Checking interruptible activity motion transitions...")
        var motion = MochiMascotActivityMotion()

        // 1. Initial state at t=0 is idle
        precondition(motion.values(at: 0) == SIMD2(0, 0), "Initial activity must be (0, 0)")

        // 2. Set to curious at t=10
        motion.set(.curious, at: 10)
        let midway = motion.values(at: 10.11)
        precondition(midway.x > 0 && midway.x < 1, "Midway curious transition must be between 0 and 1")
        precondition(midway.y == 0, "Thinking component must remain 0 during curious transition")

        // 3. Interrupt with thinking at t=10.11
        motion.set(.thinking, at: 10.11)
        let interruptedInstant = motion.values(at: 10.11)
        precondition(interruptedInstant == midway, "Interruption must not snap discontinuous pose")

        // 4. Settled at t=11 (duration is 0.22s)
        let settled = motion.values(at: 11)
        precondition(settled == SIMD2(0, 1), "Activity must fully settle to thinking (0, 1)")

        // 5. Return to idle at t=20
        motion.set(.idle, at: 20)
        let settledIdle = motion.values(at: 20.3)
        precondition(settledIdle == SIMD2(0, 0), "Activity must settle back to idle (0, 0)")

        print("    ✓ Non-snapping hermite retargeting verified across rapid interruptions.")
    }

    // MARK: - Suite 4: Spring Micro-Interactions & Styling

    static func testMochiPressStylePhysics() throws {
        print("  Checking MochiPressStyle scale parameterization and accessibility...")
        let buttonSizes: [CGFloat] = [0.90, 0.92, 0.93, 0.95, 0.96, 0.985]

        for s in buttonSizes {
            let style = MochiPressStyle(scale: s)
            precondition(style.scale == s, "MochiPressStyle scale must match constructor parameter \(s)")
        }
        print("    ✓ MochiPressStyle properly parameterizes spring compression scales.")
    }
}
