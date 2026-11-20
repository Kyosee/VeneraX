#include "crash_record.h"
#include "my_application.h"

int main(int argc, char** argv) {
  // First, so that a failure while the engine starts is recorded too.
  InstallCrashRecorder();

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
