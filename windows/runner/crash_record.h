#ifndef RUNNER_CRASH_RECORD_H_
#define RUNNER_CRASH_RECORD_H_

// Leaves a record of how the process ended in the cases the app itself cannot
// write one: a native crash is over before any log line gets out. Records go
// to %LOCALAPPDATA%\VeneraX, where the next launch reads them.

// Installs the exception filter and starts the thread that writes records.
// Does nothing where that directory cannot be had.
void InstallCrashRecorder();

// Records an ending that is not an exception, such as the watchdog closing a
// window that stopped responding.
void WriteExitRecord(const char* reason);

// Notes that the system session is ending, so that the next launch does not
// take the missing clean exit for a crash.
void MarkSessionEnded();

#endif  // RUNNER_CRASH_RECORD_H_
