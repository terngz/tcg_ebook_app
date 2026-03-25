#include <windows.h>
#include <ShellScalingApi.h>
#pragma comment(lib, "Shcore.lib")

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
  constexpr double kAspectRatio = 1.5;  // Width : Height
  constexpr wchar_t kWindowTitle[] = L"TCG FlipBook Reader";
  constexpr wchar_t kDartDataPath[] = L"data";

  std::wstring GetWebView2CachePath() {
    wchar_t temp_path[MAX_PATH];
    if (GetTempPath(MAX_PATH, temp_path) == 0) {
      return L"";
    }

    std::wstring cache_path(temp_path);
    if (!cache_path.empty() && cache_path.back() == L'\\') {
      cache_path.pop_back();
    }
    return cache_path + L"\\tcg_webview2_cache";
  }
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Enable Per-Monitor DPI Awareness V2
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // WebView2 cache folder
  std::wstring webview2_cache = GetWebView2CachePath();
  if (!webview2_cache.empty()) {
    SetEnvironmentVariable(L"WEBVIEW2_USER_DATA_FOLDER", webview2_cache.c_str());
    CreateDirectory(webview2_cache.c_str(), nullptr);
  }

  flutter::DartProject project(kDartDataPath);
  project.set_dart_entrypoint_arguments(GetCommandLineArguments());

  // Get DPI of primary monitor
  UINT dpiX, dpiY;
  HMONITOR monitor = MonitorFromWindow(nullptr, MONITOR_DEFAULTTOPRIMARY);
  GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY);

  // Physical screen size (Per-Monitor V2 returns physical pixels)
  int screenWidth  = GetSystemMetrics(SM_CXSCREEN);
  int screenHeight = GetSystemMetrics(SM_CYSCREEN);

  // Desired aspect ratio
  double aspect = kAspectRatio;

  // Window size (physical pixels)
  int windowHeight = static_cast<int>(screenHeight * 0.90);
  int windowWidth  = static_cast<int>(windowHeight * aspect);

  if (windowWidth > screenWidth * 0.90) {
    windowWidth  = static_cast<int>(screenWidth * 0.90);
    windowHeight = static_cast<int>(windowWidth / aspect);
  }

  // Center window (physical)
  int posX = (screenWidth - windowWidth) / 2;
  int posY = (screenHeight - windowHeight) / 2;

  // Convert physical → logical for Win32Window::Create
  double dpiScale = dpiX / 96.0;

  int logicalWidth  = static_cast<int>(windowWidth  / dpiScale);
  int logicalHeight = static_cast<int>(windowHeight / dpiScale);

  int logicalPosX = static_cast<int>(posX / dpiScale);
  int logicalPosY = static_cast<int>(posY / dpiScale);

  // Create window using logical coordinates
  FlutterWindow window(project);
  if (!window.Create(
          kWindowTitle,
          Win32Window::Point(logicalPosX, logicalPosY),
          Win32Window::Size(logicalWidth, logicalHeight))) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }

  window.SetQuitOnClose(true);

  MSG msg;
  while (GetMessage(&msg, nullptr, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}