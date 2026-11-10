// CoreGraphics' virtual displays (macOS 14+) are private: VirtualDisplay.h declares the classes it already ships, so
// this target has no code of its own. SwiftPM needs one source file in it.
#import "VirtualDisplay.h"
