Refine the Galaxy Continuity system across macOS and Android to match the native Apple Continuity and iPhone Mirroring experience on macOS Sequoia, deploying and validating changes directly on the connected Samsung Galaxy A70.

Working directory: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
Integrity mode: development

## Requirements

### R1. iPhone Mirroring Interaction & Input
Implement seamless keyboard and trackpad integration for the screen mirroring window: typing on the Mac keyboard transmits keystrokes and text directly into active input fields on the Galaxy, and Mac trackpad gestures (two-finger scroll, swipe navigation) seamlessly interact with the device.

### R2. Window Presentation & Seamless Continuity
Enhance the macOS screen mirroring window with a sleek smartphone bezel design and floating minimal frame. Implement automatic background reconnection over USB and Wi-Fi, and ensure clicking a phone notification on macOS brings the mirror window to focus and navigates to the relevant app.

### R3. Direct Device Deployment & Lean Verification
Build and install updated Android APK packages directly to the connected Samsung Galaxy A70 (`R58M5763N2Y`) via ADB (`/tmp/platform-tools/adb`). Conserve execution limits and steps by avoiding excessive or redundant test suites, verifying changes through direct deployment and focused functional checks on the physical device and running Mac app.

## Acceptance Criteria

### Interaction & Input Parity
- [ ] Mac keyboard keystrokes are received and typed directly into text input fields on the mirrored Galaxy screen.
- [ ] Two-finger trackpad scrolling on Mac smoothly scrolls lists and feeds on the mirrored Galaxy screen.

### Window Presentation & Continuity
- [ ] Screen mirroring window renders with a smartphone-style rounded bezel and minimal border chrome.
- [ ] Clicking a forwarded Android notification on macOS activates the mirror window and opens the corresponding notification/app on the Galaxy.
- [ ] Connection automatically re-establishes in the background without manual IP entry when the phone is connected or app relaunched.

### Device Deployment & Build
- [ ] Updated Android APK compiles and installs successfully onto the connected Samsung Galaxy A70 via `/tmp/platform-tools/adb install -r`.
- [ ] macOS application compiles successfully via `swift build` and runs with the updated mirroring features.
