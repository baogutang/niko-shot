#include "WindowSnapshotBridge.h"
#include <string.h>

CGImageRef NikoCreateWindowImage(CGRect rect, CGWindowListOption option, CGWindowID windowID) {
    // 以 macOS 14 为部署目标保留公开 API 的二进制兼容；不使用私有符号或动态查找。
    // 15 的 SDK 标注 obsolete，但本机 15.7 的原生调用对照仍可取图。不给图时 Swift 层使用新版单帧 API。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CGWindowListCreateImage(rect, option, windowID, 0);
#pragma clang diagnostic pop
}

bool NikoPixelRowsEqual(const uint8_t *left, const uint8_t *right, size_t count, uint8_t maximumDifference) {
    // 固定大小向量在 Intel 和 Apple Silicon 都可用；没有额外大图或差分缓冲。
    typedef uint8_t PixelBytes __attribute__((ext_vector_type(16)));
    size_t i = 0;
    for (; i + 16 <= count; i += 16) {
        PixelBytes a, b;
        memcpy(&a, left + i, 16); memcpy(&b, right + i, 16);
        PixelBytes difference = (a > b) ? (a - b) : (b - a);
        if (__builtin_reduce_max(difference) > maximumDifference) { return false; }
    }
    for (; i < count; i++) {
        int difference = (int)left[i] - (int)right[i];
        if (difference > maximumDifference || difference < -(int)maximumDifference) { return false; }
    }
    return true;
}
