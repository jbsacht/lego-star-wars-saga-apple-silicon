# Verification

## Scope

One Apple M2 Max, macOS 27.0.1, Xcode/macOS SDK 27, original Mac App Store Complete Saga 1.1.1 RC4. This is not a compatibility claim for every Mac, OS, game edition or level.

## Clean repository build — October 25, 2026

The setup helper was run from a separate clean copy of the upstream base plus the committed runtime changes. It compiled the runtime and generated a new local application using the installed original game. The generated application remained ignored by Git and was not installed over the player's working application.

Passed:

- Eight Python tests: matching edition, wrong edition, changed executable, missing receipt, unexpected executable path, existing-preference backup/preservation, first-run preference creation, and refusing to overwrite malformed preferences.
- Preflight against the actual original App Store application.
- Native signature bridge: original signed guest accepted; wrong identifier and ad-hoc host rejected; results match native Security validation.
- Full application packaging and strict code-signature verification.
- Byte comparison of the copied game executable and local receipt against the source installation. The values/content were not published.
- Preservation of the source edition/version metadata and source identity path in the generated bundle.
- Generated app, receipt, native binary and other private build outputs are ignored by Git.
- Native RTTI regression: downcast, crosscast, private, ambiguous, virtual diamond and null.
- Native ARB program-guard regression.
- Public-tree artifact check.

The newly generated application was checked through build/signature and metadata verification; it was not separately played through a level. The gameplay observations below come from the installed build of the same compatibility changes.

## Manual observations on the working installation

The player confirmed good keyboard movement, lightsaber activation, completing a level, saving, reloading, improved performance, and correctly fitted macOS fullscreen. A six-minute cantina idle check passed the delayed integrity check and retained normal red/green/blue output. Presentation samples were near 60 FPS in that idle scene; this is not an all-level performance guarantee.

Earlier targeted checks covered audio callback replacement and AudioConverter slot reuse, save overwrite and date formatting, physics finite classification, shader parameter readback, and zero-size Carbon-window resizing. Those support the corresponding fixes but do not prove full campaign stability.

## Remaining validation

Controller follow-up: macOS and the GameController probe detected the connected
DualSense and its button input. The player confirmed the installed keyboard
fallback worked. Mapping tests cover diagonals, simultaneous actions, custom
bindings, clearing held input and stick hysteresis. The updated loader builds
with warnings treated as errors, and the installed app passes strict signature
verification. Full analog input, a second controller, and haptics remain outside
the keyboard fallback's scope; custom bindings need an additional player check.

- Other M-series models and macOS versions.
- Long active sessions and full campaign completion.
- Controllers and audible mixing quality in this App Store edition.
- Original launch/display defaults on a Mac with no existing game preferences.
- Reproduction and diagnosis of an intermediate unsupported C++ exception path encountered while iterating on fullscreen. It was not seen in the final display check; no broad stability claim is made.

Steam and DVD editions need separate validation and are rejected by the App Store setup helper.
