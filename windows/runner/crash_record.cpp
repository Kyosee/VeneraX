#include "crash_record.h"

#include <windows.h>

#include <atomic>
#include <initializer_list>

namespace {

constexpr int kMaxFrames = 48;

// The writer may be stuck behind a lock the failed thread holds. The process
// is ending either way; it must not hang instead.
constexpr DWORD kWriteTimeoutMs = 3000;

constexpr size_t kPathCapacity = MAX_PATH * 2;

wchar_t g_crash_path[kPathCapacity];
wchar_t g_ended_path[kPathCapacity];
HANDLE g_request = nullptr;
HANDLE g_done = nullptr;
std::atomic<bool> g_installed(false);
std::atomic<bool> g_recording(false);
LPTOP_LEVEL_EXCEPTION_FILTER g_previous_filter = nullptr;

// Filled in by the thread that is ending the process, read by the writer.
// That thread may not allocate or format: the heap or the CRT may be what
// broke.
struct Pending {
  bool is_exception;
  bool has_context;
  DWORD code;
  void* address;
  ULONG_PTR stack_low;
  ULONG_PTR stack_high;
  char reason[160];
};

Pending g_pending;
CONTEXT g_context;
ULONG_PTR g_frames[kMaxFrames];
int g_frame_count = 0;

// Formats without the CRT, for the same reason.
struct Text {
  char data[8192];
  size_t length;

  void Put(const char* text) {
    while (*text != '\0' && length < sizeof(data)) {
      data[length++] = *text++;
    }
  }

  void PutHex(unsigned long long value, int min_digits) {
    char digits[16];
    int count = 0;
    do {
      digits[count++] = "0123456789abcdef"[value & 0xf];
      value >>= 4;
    } while (value != 0);
    while (count < min_digits && count < 16) {
      digits[count++] = '0';
    }
    while (count > 0 && length < sizeof(data)) {
      data[length++] = digits[--count];
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
};

Text g_text;

// "module+0xoffset": with the build's symbols that is a source line.
void PutAddress(Text* text, ULONG_PTR address) {
  HMODULE module = nullptr;
  if (::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(address), &module) &&
      module != nullptr) {
    wchar_t path[MAX_PATH];
    const DWORD size = ::GetModuleFileNameW(module, path, MAX_PATH);
    if (size > 0 && size < MAX_PATH) {
      const wchar_t* name = path;
      for (const wchar_t* cursor = path; *cursor != L'\0'; ++cursor) {
        if (*cursor == L'\\' || *cursor == L'/') {
          name = cursor + 1;
        }
      }
      char narrow[MAX_PATH * 3];
      if (::WideCharToMultiByte(CP_UTF8, 0, name, -1, narrow,
                                static_cast<int>(sizeof(narrow)), nullptr,
                                nullptr) > 0) {
        text->Put(narrow);
        text->Put("+0x");
        text->PutHex(address - reinterpret_cast<ULONG_PTR>(module), 1);
        return;
      }
    }
  }
  text->Put("0x");
  text->PutHex(address, 1);
}

// Walks the failed thread's stack from where it failed. Done here rather than
// on that thread, so that nothing there can block outside the time limit.
void CollectFrames() {
#if defined(_M_X64)
  if (!g_pending.has_context) {
    return;
  }
  CONTEXT& context = g_context;
  const ULONG_PTR high = g_pending.stack_high;
  while (g_frame_count < kMaxFrames && context.Rip != 0) {
    g_frames[g_frame_count++] = context.Rip;
    const DWORD64 sp = context.Rsp;
    DWORD64 image_base = 0;
    PRUNTIME_FUNCTION function =
        ::RtlLookupFunctionEntry(context.Rip, &image_base, nullptr);
    if (function != nullptr) {
      PVOID handler_data = nullptr;
      DWORD64 establisher_frame = 0;
      ::RtlVirtualUnwind(UNW_FLAG_NHANDLER, image_base, context.Rip, function,
                         &context, &handler_data, &establisher_frame, nullptr);
    } else {
      // A leaf function: the return address is on top of the stack.
      if (sp < g_pending.stack_low || sp + sizeof(DWORD64) > high) {
        break;
      }
      context.Rip = *reinterpret_cast<const DWORD64*>(sp);
      context.Rsp = sp + sizeof(DWORD64);
    }
    // The stack only unwinds upwards; anything else is a walk gone astray.
    if (context.Rsp <= sp || context.Rsp > high) {
      break;
    }
  }
#endif
}

void WriteRecord() {
  Text& text = g_text;
  text.length = 0;

  FILETIME now;
  ::GetSystemTimeAsFileTime(&now);
  const ULONGLONG ticks =
      (static_cast<ULONGLONG>(now.dwHighDateTime) << 32) | now.dwLowDateTime;
  // FILETIME counts 100 ns from 1601; the app works in ms from 1970.
  text.Put("time=");
  text.PutDecimal((ticks - 116444736000000000ULL) / 10000ULL);
  text.Put("\nreason=");
  if (g_pending.is_exception) {
    text.Put("exception 0x");
    text.PutHex(g_pending.code, 8);
    text.Put(" at ");
    PutAddress(&text, reinterpret_cast<ULONG_PTR>(g_pending.address));
  } else {
    text.Put(g_pending.reason);
  }
  text.Put("\n");
  for (int i = 0; i < g_frame_count; ++i) {
    text.Put(i < 10 ? "#0" : "#");
    text.PutDecimal(static_cast<unsigned long long>(i));
    text.Put(" ");
    PutAddress(&text, g_frames[i]);
    text.Put("\n");
  }

  const HANDLE file =
      ::CreateFileW(g_crash_path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  ::WriteFile(file, text.data, static_cast<DWORD>(text.length), &written,
              nullptr);
  ::CloseHandle(file);
}

// Started while the process is healthy, so that nothing has to be created or
// loaded once it is not.
DWORD WINAPI WriterThread(LPVOID) {
  ::WaitForSingleObject(g_request, INFINITE);
  // A fault here must not take the place of the one being recorded.
  __try {
    CollectFrames();
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  __try {
    WriteRecord();
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  ::SetEvent(g_done);
  return 0;
}

void RequestRecord() {
  ::SetEvent(g_request);
  ::WaitForSingleObject(g_done, kWriteTimeoutMs);
}

LONG WINAPI ExceptionFilter(EXCEPTION_POINTERS* info) {
  // One record per process: a second failure must not wait again.
  if (info != nullptr && info->ExceptionRecord != nullptr &&
      !g_recording.exchange(true)) {
    g_pending.is_exception = true;
    g_pending.code = info->ExceptionRecord->ExceptionCode;
    g_pending.address = info->ExceptionRecord->ExceptionAddress;
    if (info->ContextRecord != nullptr) {
      g_context = *info->ContextRecord;
      ::GetCurrentThreadStackLimits(&g_pending.stack_low,
                                    &g_pending.stack_high);
      g_pending.has_context = true;
    }
    RequestRecord();
  }
  return g_previous_filter != nullptr ? g_previous_filter(info)
                                      : EXCEPTION_CONTINUE_SEARCH;
}

bool JoinPath(wchar_t* out, const wchar_t* first, const wchar_t* second) {
  size_t length = 0;
  for (const wchar_t* part : {first, second}) {
    for (; *part != L'\0'; ++part) {
      if (length + 1 >= kPathCapacity) {
        return false;
      }
      out[length++] = *part;
    }
  }
  out[length] = L'\0';
  return true;
}

}  // namespace

void InstallCrashRecorder() {
  wchar_t base[kPathCapacity];
  const DWORD size = ::GetEnvironmentVariableW(
      L"LOCALAPPDATA", base, static_cast<DWORD>(kPathCapacity));
  // Zero when it is unset; the size it needs when it does not fit.
  if (size == 0 || size >= kPathCapacity) {
    return;
  }
  wchar_t directory[kPathCapacity];
  if (!JoinPath(directory, base, L"\\VeneraX") ||
      !JoinPath(g_crash_path, directory, L"\\native_crash.txt") ||
      !JoinPath(g_ended_path, directory, L"\\session_ended")) {
    return;
  }
  if (!::CreateDirectoryW(directory, nullptr) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return;
  }
  g_request = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  g_done = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (g_request == nullptr || g_done == nullptr) {
    return;
  }
  const HANDLE writer =
      ::CreateThread(nullptr, 0, WriterThread, nullptr, 0, nullptr);
  if (writer == nullptr) {
    return;
  }
  ::CloseHandle(writer);
  g_installed = true;
  g_previous_filter = ::SetUnhandledExceptionFilter(ExceptionFilter);
}

void WriteExitRecord(const char* reason) {
  if (!g_installed.load() || g_recording.exchange(true)) {
    return;
  }
  size_t length = 0;
  for (; reason[length] != '\0' && length + 1 < sizeof(g_pending.reason);
       ++length) {
    g_pending.reason[length] = reason[length];
  }
  g_pending.reason[length] = '\0';
  RequestRecord();
}

void MarkSessionEnded() {
  if (!g_installed.load()) {
    return;
  }
  // Created afresh, so that its time is this session's end.
  ::DeleteFileW(g_ended_path);
  const HANDLE file =
      ::CreateFileW(g_ended_path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    ::CloseHandle(file);
  }
}
