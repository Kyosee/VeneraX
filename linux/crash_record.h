#ifndef RUNNER_CRASH_RECORD_H_
#define RUNNER_CRASH_RECORD_H_

// Leaves a record of how the process ended in the cases the app itself cannot
// write one: a native crash is over before any log line gets out. Records go
// to $XDG_CACHE_HOME/venerax, or ~/.cache/venerax, where the next launch
// reads them.

// Installs the signal handlers. Does nothing where that directory cannot be
// had.
void InstallCrashRecorder();

#endif  // RUNNER_CRASH_RECORD_H_
