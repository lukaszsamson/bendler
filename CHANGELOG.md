# Changelog

## Unreleased

This release is not published yet. The current tree includes:

- A supervised CPU port backend for bounded pure Bend functions, with generated
  Elixir bindings, typed codecs, bounded admission, deadlines, telemetry, and
  launcher-owned worker termination.
- Boundary support for the documented scalar, string, byte-buffer, list, tuple,
  `Maybe`, `Result`, map, and same-file user-datatype subset, including codec
  validation and decoded-allocation budgets.
- Build isolation and reproducible artifact fingerprints, consumer-release
  support without Bend on `PATH`, and demos covering real port workloads.
- An experimental opt-in NIF backend with bounded asynchronous submission,
  caller monitoring, checked initialization, caller-side deadlines, and
  VM-lifetime pinning to keep live runtime code mapped. Graceful NIF unload is
  not implemented; the port backend remains the MVP default.
- An experimental GPU-shaped port lane for programs using `!`; performance and
  availability depend on the kernel and installed platform toolchain.
- Public macOS 15 arm64 / Ubuntu 24.04 x86_64 CI with checksum-pinned Bend and
  LLVM, commit-pinned actions, ASan, release and isolated NIF checks. GPU builds
  retain a CPU-capable executable when no visible device produces a sidecar.

## Support status

The supported toolchain is Bend 2.0.20 with OTP 28. CI pins OTP 28.1,
Elixir 1.20.3 and LLVM 21.1.8. macOS 15 arm64 and Linux x86_64 / Ubuntu 24.04
have passed the checked-in CI workflow, including the isolated experimental
NIF probes. Windows is not supported.
