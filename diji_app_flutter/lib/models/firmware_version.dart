/// Semantic version triple for Dijilele firmware (matches BLE telemetry 0x57/0x58/0x59).
class FirmwareVersion {
  final int major;
  final int minor;
  final int patch;

  const FirmwareVersion(this.major, this.minor, this.patch);

  /// -1 if this is older than [other], 0 if equal, 1 if newer.
  int compareTo(FirmwareVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool isLessThan(FirmwareVersion other) => compareTo(other) < 0;

  static FirmwareVersion? tryParse(String s) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\s*$').firstMatch(s.trim());
    if (m == null) return null;
    return FirmwareVersion(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }

  @override
  String toString() => '$major.$minor.$patch';

  @override
  bool operator ==(Object other) =>
      other is FirmwareVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}
