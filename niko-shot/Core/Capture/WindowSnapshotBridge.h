#include <CoreGraphics/CoreGraphics.h>

// macOS 14 部署兼容的公开接口；后续系统不给图时 Swift 层有受支持的单帧回退。
CGImageRef _Nullable NikoCreateWindowImage(CGRect rect, CGWindowListOption option,
                                         CGWindowID windowID) CF_RETURNS_RETAINED;

// 原始重叠逐通道校验；颜色微小渲染抖动不能掩盖正文错位或新增内容。
bool NikoPixelRowsEqual(const uint8_t * _Nonnull left, const uint8_t * _Nonnull right,
                        size_t count, uint8_t maximumDifference);
