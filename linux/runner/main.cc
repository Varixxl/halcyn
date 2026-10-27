#include <cstdlib>

#include "my_application.h"

int main(int argc, char** argv) {
  // The streaming sign-in windows are WebKitGTK. Its DMA-BUF renderer breaks the
  // Wayland connection on NVIDIA ("Error 71 (Protocol error)"), which takes the whole
  // app down. Off unless the user set it themselves.
  setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
