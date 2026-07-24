import 'package:flutter_memory_info/flutter_memory_info.dart' as memory_info;

class MemoryInfo {
  static Future<int?> getFreePhysicalMemorySize() {
    return memory_info.MemoryInfo.getFreePhysicalMemorySize();
  }

  /// Total physical RAM in bytes. Used to gauge whether a device can run a
  /// given local model size. Available on all supported platforms.
  static Future<int?> getTotalPhysicalMemorySize() {
    return memory_info.MemoryInfo.getTotalPhysicalMemorySize();
  }
}
