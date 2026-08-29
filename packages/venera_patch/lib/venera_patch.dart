/// Hot-update runtime for Venera.
///
/// Kill switches, config overlays, the GitHub-backed distribution channel, and
/// the adapter that turns a loaded VIR bundle into the overrides a generated
/// seam calls.
///
/// The host app depends on this package alone. The interpreter
/// (`venera_patch_vm`) is re-exported below rather than imported directly by the
/// app, so the boundary between "runtime plumbing" and "the thing that executes
/// patch code" stays in one place — and the app's dependency list keeps naming
/// one hot-update package instead of two that must be kept in step.
library;

export 'package:venera_patch_vm/venera_patch_vm.dart'
    show
        HostBridge,
        PatchLoadFault,
        PatchVmFault,
        UnboundMemberFault,
        ResourceLimitFault,
        VirLoader,
        VmLimits,
        VmProgram;

export 'src/core_bindings.dart';
export 'src/manifest.dart';
export 'src/kill_switch.dart';
export 'src/overlay.dart';
export 'src/registry.dart';
export 'src/seam.dart';
export 'src/signature.dart';
export 'src/slot.dart';
export 'src/store.dart';
export 'src/vm_bridge.dart';
