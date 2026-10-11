/// Target for xcframework builds. This is a separate file so that
/// our runtime code doesn't need to import build code.
///
///   * `arm64` - Apple Silicon (aarch64) macOS only. This is the default
///     since Hallows only ships for Apple Silicon.
///   * `native` - The architecture of the build host.
///   * `universal` - A fat arm64 + x86_64 binary.
pub const Target = enum { arm64, native, universal };
