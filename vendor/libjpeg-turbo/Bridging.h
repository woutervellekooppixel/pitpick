// Lets Swift call libjpeg-turbo (TurboJPEG 3 API). Used by the Apple Silicon build only.
#include "turbojpeg.h"

// tj3Init is a function-like macro in libjpeg-turbo 3.2, which Swift cannot call.
static inline tjhandle pitpick_tj3_init(int initType) { return tj3Init(initType); }
