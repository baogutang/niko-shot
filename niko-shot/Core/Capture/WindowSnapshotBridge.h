#include <CoreGraphics/CoreGraphics.h>

// macOS 14 部署兼容的公开接口；后续系统不给图时 Swift 层有受支持的单帧回退。
CGImageRef _Nullable NikoCreateWindowImage(CGRect rect, CGWindowListOption option,
                                         CGWindowID windowID) CF_RETURNS_RETAINED;
