// The `caw/video` method channel on Windows: caps, start, frame, finish and
// cancel, handed to the Media Foundation encoder (video_encoder.h).
#ifndef RUNNER_VIDEO_CHANNEL_H_
#define RUNNER_VIDEO_CHANNEL_H_

#include <flutter/binary_messenger.h>

// Registers the channel on |messenger|; it lives until the process ends or
// UnregisterVideoChannel is called (the window's OnDestroy).
void RegisterVideoChannel(flutter::BinaryMessenger* messenger);
void UnregisterVideoChannel();

#endif  // RUNNER_VIDEO_CHANNEL_H_
