# Adversarial Empirical Verification Report: Milestone M-IT3-1

**Milestone**: M-IT3-1: iPhone Mirroring Parity & Presentation  
**Agent**: `m1_it3_challenger_1` (Empirical Challenger / Critic & Specialist)  
**Date**: 2026-11-08  
**Verdict**: **REQUEST_CHANGES**

---

## 1. Observation

Direct empirical stress testing and static audit of the codebase revealed the following observations:

### Obs 1.1: ADB Shell Fallback Crashes with NullPointerException on Non-ASCII Text & Fails on Quotes
In `mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift:122-139`:
```swift
122:     public func sendTextInput(text: String) {
123:         let msg = ContinuityMessage(type: "input_text", text: text)
124:         ServerManager.shared.broadcastMessage(msg)
125: 
126:         // ADB fast-path: escape shell metacharacters and replace spaces with %s
127:         let escaped = text.replacingOccurrences(of: " ", with: "%s")
128:             .replacingOccurrences(of: "\\", with: "\\\\")
129:             .replacingOccurrences(of: "\"", with: "\\\"")
130:             .replacingOccurrences(of: "$", with: "\\$")
131:             .replacingOccurrences(of: "`", with: "\\`")
132:             .replacingOccurrences(of: "&", with: "\\&")
133:             .replacingOccurrences(of: ";", with: "\\;")
134:             .replacingOccurrences(of: "(", with: "\\(")
135:             .replacingOccurrences(of: ")", with: "\\)")
136:         if !escaped.isEmpty {
137:             dispatchAdbInput(args: ["text", escaped])
138:         }
139:     }
```
When typing non-ASCII characters (Cyrillic, Greek, CJK, Emoji) or text with single quotes (e.g. `'`, `it's`, `don't`), `dispatchAdbInput` executes `/tmp/platform-tools/adb shell input text <escaped>`.

Verbatim Terminal Command and Execution:
```bash
/tmp/platform-tools/adb shell input text "Привет"
```
Verbatim Error Output:
```
java.lang.NullPointerException: Attempt to get length of null array
	at com.android.commands.input.Input$InputText.sendText(Input.java:168)
	at com.android.commands.input.Input$InputText.run(Input.java:140)
	at com.android.commands.input.Input.onRun(Input.java:107)
	at com.android.internal.os.BaseCommand.run(BaseCommand.java:60)
	at com.android.commands.input.Input.main(Input.java:71)
	at com.android.internal.os.RuntimeInit.nativeFinishInit(Native Method)
	at com.android.internal.os.RuntimeInit.main(RuntimeInit.java:409)
```

Verbatim Terminal Command with Single Quote:
```bash
/tmp/platform-tools/adb shell input text "it's%sfine"
```
Verbatim Error Output:
```
/system/bin/sh: no closing quote
```
Exit code: 1.

Furthermore, `sendTextInput` dispatches `dispatchAdbInput` unconditionally even when WebSocket clients are active, causing concurrent dual-injection (once over WebSocket via `ContinuityAccessibilityService.handleTextInput`, and once over ADB `input text`).

### Obs 1.2: Swift Unit Test Regression in `ScreenMirroringAdversarialTests.swift`
In `mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift:255-269`:
```swift
255:     private func startStallWatchdog() {
256:         stopStallWatchdog()
257:         lastFrameReceivedDate = Date()
258:         let timer = DispatchSource.makeTimerSource(queue: queue)
259:         timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
260:         timer.setEventHandler { [weak self] in
261:             guard let self = self, let last = self.lastFrameReceivedDate else { return }
262:             if Date().timeIntervalSince(last) > 30.0 {
263:                 print("[ScreenMirroringService] Stream stalled (>30s), issuing screen_stop")
264:                 self.stopMirroring(reason: "stream_stalled")
265:             }
266:         }
267:         timer.resume()
268:         stallCheckTimer = timer
269:     }
```
Commit `7fba5459751293dc4af782a2d453958d2e0e7dca` changed line 262 timeout check from `> 5.0` to `> 30.0`.
However, `mac/Tests/GalaxyContinuityTests/ScreenMirroringAdversarialTests.swift:223-228` specifies:
```swift
223:         // Wait 5.5s for watchdog (>5000ms) to fire stopMirroring(reason: "stream_stalled")
224:         try await Task.sleep(nanoseconds: 5_500_000_000)
225: 
226:         let activeAfterStall = await MainActor.run { DeviceState.shared.isScreenMirroringActive }
227:         #expect(activeAfterStall == false)
```
When running the full Swift test suite:
```bash
cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
```
Verbatim Output:
```
✘ Test "Watchdog triggers stream_stalled when inactive for >5000ms" recorded an issue at ScreenMirroringAdversarialTests.swift:227:9: Expectation failed: (activeAfterStall → true) == false
✘ Test "Watchdog triggers stream_stalled when inactive for >5000ms" failed after 6.114 seconds with 1 issue.
✘ Suite "Screen Mirroring Adversarial Stress Tests" failed after 10.196 seconds with 1 issue.
✘ Test run with 112 tests in 14 suites failed after 10.197 seconds with 1 issue.
```

### Obs 1.3: Empirical Android Input Stress Test Suite (`AdversarialInputStressTest.kt`)
Created and executed `android/app/src/test/java/com/galaxycontinuity/app/AdversarialInputStressTest.kt` verifying:
1. `testCyrillicInputTextRoundtripAndLength` (PASS)
2. `testGreekInputTextRoundtrip` (PASS)
3. `testAsianCJKInputTextRoundtrip` (PASS)
4. `testMultiByteComplexEmojiInputText` (PASS)
5. `testTextInsertionCursorMathAtBeginningMiddleEnd` (PASS)
6. `testExtremeScrollDeltasClampedWithinDisplayBounds` (PASS)
7. `testNegativeAndExcessCoordinatesClamped` (PASS)
8. `testSubpixelJitterDeadbandBoundary` (hypot < 1.0 suppressed, hypot >= 1.0 passed) (PASS)
9. `testRapidBackspaceOnEmptyField` (empty field & cursor 0 safely returns null) (PASS)
10. `testKeycodeMappingsForAllStandardKeys` (17 keys tested) (PASS)
11. `testProtocolRoundtripRapidSerialization1000Events` (1000 events in 0.029s) (PASS)
12. `testNotificationOpenRoundtripWithComplexPackageNames` (PASS)
13. `testInputEventScrollBackwardCompatibility` (PASS)

Verbatim Execution:
```bash
export JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home && export ANDROID_HOME=~/Library/Android/sdk && cd android && ./gradlew testDebugUnitTest --no-daemon
```
Result: `BUILD SUCCESSFUL in 5s`. 13/13 adversarial tests and all 67 prior tests passed with 0 errors.

### Obs 1.4: Empirical Mac Input Parity Test Suite (`InputParityAdversarialTests.swift`)
Created and executed `mac/Tests/GalaxyContinuityTests/InputParityAdversarialTests.swift` verifying:
1. `testUnicodeAndEmojiInputText` (PASS)
2. `testShellMetacharactersEscaping` (PASS)
3. `testExtremeScrollDeltas` (PASS)
4. `testScrollRoundtripPrecision` (PASS)
5. `testKeyResolutionAllStandardKeys` (PASS)
6. `testRapidBackspaceBurst` (500 events) (PASS)
7. `testNotificationOpenSerialization` (PASS)

Verbatim Execution:
```bash
cd mac && swift test --filter InputParityAdversarialTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
```
Result: `✔ Test run with 7 tests in 1 suite passed after 0.006 seconds`.

---

## 2. Logic Chain

1. **ADB Fallback Flaw (Obs 1.1)**:
   - Android OS implementation of `input text` (`com.android.commands.input.Input.java:168`) relies on `KeyCharacterMap.getEvents()`.
   - Non-ASCII characters (Cyrillic, Greek, CJK, Emoji) do not have mappings in Android default physical key character maps, returning `null` array and throwing `NullPointerException`.
   - Furthermore, Android's `/system/bin/sh` fails on unescaped single quotes (`/system/bin/sh: no closing quote`).
   - In `ScreenMirroringService.swift`, `sendTextInput` always dispatches `dispatchAdbInput(args: ["text", escaped])` concurrently in addition to broadcasting over WebSocket.
   - When typing on the Mac keyboard into the mirrored window, this causes duplicate text injection if WebSocket is active and ADB crashes when non-ASCII or apostrophes/single quotes are entered.
   - *Conclusion*: ADB fallback in `sendTextInput` must either only be invoked when no WebSocket client is connected AND the text is strictly ASCII alphanumeric (`^[a-zA-Z0-9._%+-]+$`), or omitted in favor of the primary WebSocket `input_text` channel.

2. **Watchdog Test Discrepancy (Obs 1.2)**:
   - In commit `7fba5459751293dc4af782a2d453958d2e0e7dca`, `ScreenMirroringService.swift` line 262 increased stall timeout from `5.0` to `30.0` seconds.
   - The test `testWatchdogStallRecovery` in `ScreenMirroringAdversarialTests.swift` waits `5.5` seconds expecting `isScreenMirroringActive == false`.
   - Because 5.5s < 30.0s, the watchdog does not trigger, and the assertion `#expect(activeAfterStall == false)` fails.
   - *Conclusion*: The stall timeout contract between `ScreenMirroringService.swift` and `ScreenMirroringAdversarialTests.swift` is broken and must be harmonized.

3. **Input Clamping and Gesture Integrity (Obs 1.3 & 1.4)**:
   - `RemoteInputMapper.resolveScrollStroke` correctly bounds all coordinates to screen dimensions `[0f, displayWidth]` and `[0f, displayHeight]`, duration to `[60L, 150L]`, and suppresses micro-jitter `< 1.0 pt`.
   - Rapid DEL on empty fields and cursor 0 is safe against `IndexOutOfBoundsException`.
   - Protocol serialization across Swift and Kotlin handles all message schemas without data loss.

4. **Verdict Synthesis**:
   - Because Obs 1.1 introduces live device crashes and duplicate input risks during normal typing (e.g. typing contractions like "it's" or non-ASCII characters), and Obs 1.2 causes regression in `swift test`, the implementation cannot be approved in its current state.
   - Verdict is **REQUEST_CHANGES**.

---

## 3. Caveats

- Android accessibility text injection (`ACTION_SET_TEXT`) was verified via JVM unit tests and logic modeling against Android SDK contracts; full end-to-end device testing with live accessibility focus node relies on physical device execution in M-IT3-2.
- The ADB crash does not crash the Mac app itself because `dispatchAdbInput` spawns a background Process without throwing; however, it causes failed commands on the Android device and log pollution.

---

## 4. Conclusion

**Verdict**: **REQUEST_CHANGES**

Required fixes for the worker:
1. **Fix ADB Text Input Fallback in `ScreenMirroringService.swift`**:
   - Do not invoke `dispatchAdbInput(args: ["text", escaped])` if WebSocket clients are connected to avoid duplicate text injection.
   - Guard `dispatchAdbInput` against non-ASCII characters (e.g., check `text.allSatisfy { $0.isASCII && $0 != "'" }`) to avoid Android OS `NullPointerException` and shell quote parsing errors.
2. **Harmonize Watchdog Stall Timeout in `ScreenMirroringService.swift` / `ScreenMirroringAdversarialTests.swift`**:
   - Align watchdog stall timeout in `ScreenMirroringService.swift:262` (e.g., 5.0 seconds) with `ScreenMirroringAdversarialTests.swift:224` (5.5s sleep) so that the entire Swift test suite passes cleanly.

---

## 5. Verification Method

### 5.1 Verifying the Findings
1. **Reproduce ADB Shell Crash on Android Device**:
   ```bash
   /tmp/platform-tools/adb shell input text "Привет"
   /tmp/platform-tools/adb shell input text "it's%sfine"
   ```
   *Expected Error*: NPE on "Привет" and `/system/bin/sh: no closing quote` on "it's%sfine".

2. **Reproduce Watchdog Test Failure in Swift Test Suite**:
   ```bash
   cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter testWatchdogStallRecovery
   ```
   *Expected Failure*: `Expectation failed: (activeAfterStall → true) == false`.

3. **Verify Android Adversarial Input Test Suite**:
   ```bash
   export JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home && export ANDROID_HOME=~/Library/Android/sdk && cd android && ./gradlew testDebugUnitTest --no-daemon
   ```
   *Expected Result*: All 13 tests in `AdversarialInputStressTest` pass.

4. **Verify Mac Input Parity Test Suite**:
   ```bash
   cd mac && swift test --filter InputParityAdversarialTests -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
   ```
   *Expected Result*: All 7 tests in `InputParityAdversarialTests` pass.

### 5.2 Files to Inspect
- `mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift` (lines 122–139, 255–269)
- `mac/Tests/GalaxyContinuityTests/ScreenMirroringAdversarialTests.swift` (lines 211–228)
- `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt` (lines 189–236)
- `android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt` (lines 70–110)

### 5.3 Invalidation Conditions for REQUEST_CHANGES
- `ScreenMirroringService.swift` guards ADB text fallback against non-ASCII and single quotes, and avoids duplicate injection when WebSocket is connected.
- Full `swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks` passes with 0 issues.
