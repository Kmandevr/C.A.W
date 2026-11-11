// The music video's MP4 encoder on Windows: RGBA frames (as NV12) to H.264 and a
// 16-bit PCM WAV to AAC through the Media Foundation sink writer (platform APIs only).
#ifndef RUNNER_VIDEO_ENCODER_H_
#define RUNNER_VIDEO_ENCODER_H_

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>

struct IMFSinkWriter;

class Mp4Encoder {
 public:
  Mp4Encoder() = default;
  ~Mp4Encoder();
  Mp4Encoder(const Mp4Encoder&) = delete;
  Mp4Encoder& operator=(const Mp4Encoder&) = delete;

  // The largest frame, long side and short side. [Assumption] Microsoft's
  // H.264 encoder MFT's documented maximum of 4096 x 2304; a hardware encoder
  // may take less, which Start reports.
  static void Caps(int* max_long, int* max_short);

  // Each returns an empty string on success, else what went wrong.
  std::string Start(int width, int height, int fps, int bitrate,
                    const std::wstring& audio_wav, const std::wstring& output);
  // |rgba| is width * height * 4 bytes, top row first.
  std::string AddFrame(const uint8_t* rgba, size_t size);
  std::string Finish();
  // Stops and deletes the partial file; safe at any time.
  void Cancel();

  bool running() const { return writer_ != nullptr; }

 private:
  std::string WriteAudioUntil(long long time_100ns);
  void Release();

  IMFSinkWriter* writer_ = nullptr;
  bool mf_started_ = false;
  unsigned long video_stream_ = 0;
  unsigned long audio_stream_ = 0;
  bool has_audio_ = false;
  int width_ = 0;
  int height_ = 0;
  int fps_ = 30;
  long long frames_ = 0;
  std::wstring output_;

  // The WAV being read, a chunk at a time, in step with the frames.
  FILE* wav_ = nullptr;
  int rate_ = 0;
  int channels_ = 0;
  long long audio_frames_total_ = 0;
  long long audio_frames_done_ = 0;
};

#endif  // RUNNER_VIDEO_ENCODER_H_
