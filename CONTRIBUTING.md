# Contributing

Keep changes small and explain the observed failure, the change, and verification. Identify the exact game edition: the App Store 1.1.1 RC4 runtime is the validated target of this contribution.

The original project's history supports several games. Avoid changing those paths without tests. The source installation, game archives, receipts, preferences and saves must never enter Git. Build artifacts remain local.

Run the setup-helper unit tests with `python3 -m unittest discover -s tests -v`. Run applicable native checks from `native/`; `make test-rtti-bridge` and `make test-arb-program-guard` do not require game assets. Bridge checks requiring a game must use your own local original installation.

For changes to runtime dispatch, exercise the affected ABI and native readback, not only mocked calls. For window/input changes, test entry/exit, switching applications, and actual gameplay. Preserve signature validation and source edition metadata.

Read `NOTICE.md` before proposing a license or a binary release. This repository does not claim that missing upstream licensing has been resolved.
