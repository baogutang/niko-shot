#include "WindowSnapshotBridge.h"

CGImageRef NikoCreateWindowImage(CGRect rect, CGWindowListOption option, CGWindowID windowID) {
    // 以 macOS 14 为部署目标保留公开 API 的二进制兼容；不使用私有符号或动态查找。
    // 15 的 SDK 标注 obsolete，但运行时仍可取图；不给图时 Swift 层改用 ScreenCaptureKit 单帧。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CGWindowListCreateImage(rect, option, windowID, kCGWindowImageBestResolution);
#pragma clang diagnostic pop
}
