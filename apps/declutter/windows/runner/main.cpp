#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One Prune at a time: a second one would wipe the first one's photo
  // copies and previews on start while it is still using them. Starting it
  // again just brings the open window forward.
  HANDLE single = ::CreateMutexW(nullptr, TRUE, L"Local\\Prune.SingleInstance");
  if (single != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND open = ::FindWindowW(nullptr, L"Prune")) {
      ::ShowWindow(open, SW_RESTORE);
      ::SetForegroundWindow(open);
    }
    ::CloseHandle(single);
    return EXIT_SUCCESS;
  }

  // Windows 11 may move a minimised or hidden app onto its slow, power-saving
  // cores ("EcoQoS"), most of all on battery. The photo check is work the
  // user is waiting for, so ask to run at normal speed.
  PROCESS_POWER_THROTTLING_STATE power{};
  power.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
  power.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
  power.StateMask = 0;
  ::SetProcessInformation(::GetCurrentProcess(), ProcessPowerThrottling,
                          &power, sizeof(power));

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Prune", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single != nullptr) ::CloseHandle(single);
  return EXIT_SUCCESS;
}
