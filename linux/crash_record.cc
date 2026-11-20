#include "crash_record.h"

#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <initializer_list>

namespace {

constexpr int kCrashSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT};
constexpr int kSignalCount = sizeof(kCrashSignals) / sizeof(kCrashSignals[0]);
constexpr int kMaxFrames = 64;
constexpr size_t kPathCapacity = 4096;

// Writing may wait on a lock the failed thread holds, or on a file that never
// opens. The process is ending either way; it must not hang instead.
constexpr unsigned kWriteTimeoutSeconds = 3;

char g_crash_path[kPathCapacity];
char g_ended_path[kPathCapacity];
pid_t g_pid = 0;
struct sigaction g_previous[kSignalCount];
std::atomic_flag g_recording = ATOMIC_FLAG_INIT;
volatile sig_atomic_t g_crash_number = 0;

// A thread whose stack overflowed has no room left to run a handler on.
alignas(16) char g_alt_stack[64 * 1024];

// Everything below runs inside signal handlers: no stdio, no allocation,
// only calls that are safe there.
struct Line {
  char data[256];
  size_t length = 0;

  void Put(const char* text) {
    while (*text != '\0' && length < sizeof(data)) {
      data[length++] = *text++;
    }
  }

  void PutDecimal(unsigned long long value) {
    char digits[20];
    int count = 0;
    do {
      digits[count++] = static_cast<char>('0' + value % 10);
      value /= 10;
    } while (value != 0);
    while (count > 0 && length < sizeof(data)) {
      data[length++] = digits[--count];
    }
  }

  void PutHex(uintptr_t value) {
    char digits[16];
    int count = 0;
    do {
      digits[count++] = "0123456789abcdef"[value & 0xf];
      value >>= 4;
    } while (value != 0);
    while (count > 0 && length < sizeof(data)) {
      data[length++] = digits[--count];
    }
  }
};

const char* SignalName(int number) {
  switch (number) {
    case SIGSEGV:
      return "SIGSEGV";
    case SIGBUS:
      return "SIGBUS";
    case SIGILL:
      return "SIGILL";
    case SIGFPE:
      return "SIGFPE";
    case SIGABRT:
      return "SIGABRT";
  }
  return "unknown";
}

// Raised by the instruction that failed, so running it again raises it again.
// Anything sent with kill() or abort() is not.
bool IsFault(int number, const siginfo_t* info) {
  return info != nullptr && info->si_code > 0 && number != SIGABRT;
}

void WriteAll(int fd, const char* data, size_t size) {
  while (size > 0) {
    const ssize_t written = write(fd, data, size);
    if (written < 0 && errno == EINTR) {
      continue;
    }
    if (written <= 0) {
      return;
    }
    data += written;
    size -= static_cast<size_t>(written);
  }
}

void WriteCrashRecord(int number, const siginfo_t* info) {
  const int fd =
      open(g_crash_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) {
    return;
  }
  timespec now = {0, 0};
  clock_gettime(CLOCK_REALTIME, &now);
  Line line;
  line.Put("time=");
  line.PutDecimal(static_cast<unsigned long long>(now.tv_sec) * 1000 +
                  static_cast<unsigned long long>(now.tv_nsec) / 1000000);
  line.Put("\nreason=signal ");
  line.PutDecimal(static_cast<unsigned long long>(number));
  line.Put(" (");
  line.Put(SignalName(number));
  line.Put(")");
  if (IsFault(number, info)) {
    line.Put(" at 0x");
    line.PutHex(reinterpret_cast<uintptr_t>(info->si_addr));
  }
  line.Put("\n");
  // Out before the stack, which is the part that could still fail.
  WriteAll(fd, line.data, line.length);
  void* frames[kMaxFrames];
  const int count = backtrace(frames, kMaxFrames);
  if (count > 0) {
    backtrace_symbols_fd(frames, count, fd);
  }
  close(fd);
}

// Writing the record took too long: end the process with the signal it was
// ending with. A thread that does not have it blocked takes it at once.
void OnRecordTimeout(int) {
  struct sigaction fallback = {};
  fallback.sa_handler = SIG_DFL;
  sigemptyset(&fallback.sa_mask);
  sigaction(g_crash_number, &fallback, nullptr);
  kill(getpid(), g_crash_number);
  // Where no thread can, SIGALRM's default action ends it shortly.
  sigaction(SIGALRM, &fallback, nullptr);
  alarm(1);
}

void OnCrash(int number, siginfo_t* info, void* context) {
  const int saved_errno = errno;
  // A child forked without exec inherits this handler but is not the app.
  if (getpid() == g_pid && !g_recording.test_and_set()) {
    g_crash_number = number;
    struct sigaction timeout = {};
    timeout.sa_handler = OnRecordTimeout;
    sigemptyset(&timeout.sa_mask);
    struct sigaction alarm_previous = {};
    sigaction(SIGALRM, &timeout, &alarm_previous);
    const unsigned alarm_pending = alarm(kWriteTimeoutSeconds);
    WriteCrashRecord(number, info);
    alarm(alarm_pending);
    sigaction(SIGALRM, &alarm_previous, nullptr);
  }
  int index = 0;
  while (index < kSignalCount && kCrashSignals[index] != number) {
    ++index;
  }
  if (index == kSignalCount) {
    return;
  }
  // Hand the signal back to whoever had it before, as if never caught here.
  const struct sigaction& previous = g_previous[index];
  sigaction(number, &previous, nullptr);
  errno = saved_errno;
  if (previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN) {
    if ((previous.sa_flags & SA_SIGINFO) != 0) {
      previous.sa_sigaction(number, info, context);
    } else {
      previous.sa_handler(number);
    }
    return;
  }
  // A fault comes back when this returns; anything sent is sent again.
  if (!IsFault(number, info)) {
    raise(number);
  }
}

void OnTerminate(int number) {
  if (getpid() == g_pid) {
    // Created afresh, so that its time is this session's end.
    unlink(g_ended_path);
    const int fd =
        open(g_ended_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd >= 0) {
      close(fd);
    }
  }
  struct sigaction fallback = {};
  fallback.sa_handler = SIG_DFL;
  sigemptyset(&fallback.sa_mask);
  sigaction(number, &fallback, nullptr);
  raise(number);
}

bool JoinPath(char* out, const char* first, const char* second) {
  size_t length = 0;
  for (const char* part : {first, second}) {
    for (; *part != '\0'; ++part) {
      if (length + 1 >= kPathCapacity) {
        return false;
      }
      out[length++] = *part;
    }
  }
  out[length] = '\0';
  return true;
}

bool MakeDirectory(const char* path) {
  return mkdir(path, 0700) == 0 || errno == EEXIST;
}

bool ResolveDirectory(char* directory) {
  // XDG ignores a relative path.
  const char* cache = getenv("XDG_CACHE_HOME");
  if (cache != nullptr && cache[0] == '/') {
    return MakeDirectory(cache) && JoinPath(directory, cache, "/venerax");
  }
  const char* home = getenv("HOME");
  if (home == nullptr || home[0] == '\0') {
    return false;
  }
  char base[kPathCapacity];
  return JoinPath(base, home, "/.cache") && MakeDirectory(base) &&
         JoinPath(directory, base, "/venerax");
}

}  // namespace

void InstallCrashRecorder() {
  char directory[kPathCapacity];
  if (!ResolveDirectory(directory) || !MakeDirectory(directory) ||
      !JoinPath(g_crash_path, directory, "/native_crash.txt") ||
      !JoinPath(g_ended_path, directory, "/session_ended")) {
    return;
  }
  g_pid = getpid();

  // The first call loads the unwinder, which must not happen in a handler.
  void* warm_up[1];
  backtrace(warm_up, 1);

  // Only for this thread: each thread needs its own.
  stack_t current = {};
  if (sigaltstack(nullptr, &current) == 0 &&
      (current.ss_flags & SS_DISABLE) != 0) {
    stack_t alternate = {};
    alternate.ss_sp = g_alt_stack;
    alternate.ss_size = sizeof(g_alt_stack);
    sigaltstack(&alternate, nullptr);
  }

  struct sigaction action = {};
  action.sa_sigaction = OnCrash;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&action.sa_mask);
  for (int i = 0; i < kSignalCount; ++i) {
    sigaction(kCrashSignals[i], &action, &g_previous[i]);
  }

  // Where someone already handles or ignores SIGTERM, it may not end the
  // process, and a marker would hide a later crash.
  struct sigaction term = {};
  if (sigaction(SIGTERM, nullptr, &term) == 0 &&
      term.sa_handler == SIG_DFL) {
    term = {};
    term.sa_handler = OnTerminate;
    sigemptyset(&term.sa_mask);
    sigaction(SIGTERM, &term, nullptr);
  }
}
