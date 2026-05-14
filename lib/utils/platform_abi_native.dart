import 'dart:ffi';

bool get isWindowsArm64 => Abi.current() == Abi.windowsArm64;
