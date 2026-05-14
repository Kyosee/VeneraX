import 'package:flutter_memory_info/flutter_memory_info.dart' as memory_info;

class MemoryInfo {
  static Future<int?> getFreePhysicalMemorySize() {
    return memory_info.MemoryInfo.getFreePhysicalMemorySize();
  }
}
