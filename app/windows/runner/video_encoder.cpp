// The music video's MP4 encoder on Windows (see video_encoder.h). Sources
// (Microsoft Learn, read 2026-11-11): "Tutorial: Using the Sink Writer to
// Encode Video" (the sink writer steps), "AAC Encoder" (PCM 16-bit input,
// 44.1 or 48 kHz, 1 or 2 channels; MF_MT_AUDIO_AVG_BYTES_PER_SECOND 12000,
// 16000, 20000 or 24000), and "H.264 Video Encoder" (input I420, IYUV, NV12,
// YUY2 or YV12; output MFVideoFormat_H264). Frames are converted to NV12 here
// (BT.601 limited range, as the Android encoder does), so no colour converter
// is needed between the writer and the encoder.
#include "video_encoder.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>

#include <algorithm>
#include <cstring>
#include <vector>

// Linked in CMakeLists.txt: mfplat.lib, mfreadwrite.lib, mfuuid.lib.

namespace {

template <class T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

std::string Hr(const char* what, HRESULT hr) {
  char buf[96];
  std::snprintf(buf, sizeof(buf), "%s failed (0x%08lX)", what, static_cast<unsigned long>(hr));
  return buf;
}

uint32_t Le32(const unsigned char* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

uint16_t Le16(const unsigned char* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

// Finds a 16-bit PCM WAV's format and data; false when it isn't one.
bool ReadWav(FILE* f, int* rate, int* channels, long long* data_offset, long long* data_bytes) {
  unsigned char head[12];
  if (std::fseek(f, 0, SEEK_SET) != 0 || std::fread(head, 1, 12, f) != 12) return false;
  if (std::memcmp(head, "RIFF", 4) != 0 || std::memcmp(head + 8, "WAVE", 4) != 0) return false;
  _fseeki64(f, 0, SEEK_END);
  const long long length = _ftelli64(f);
  long long pos = 12;
  int format = 0, bits = 0;
  *rate = 0;
  *channels = 0;
  while (pos + 8 <= length) {
    unsigned char h[8];
    _fseeki64(f, pos, SEEK_SET);
    if (std::fread(h, 1, 8, f) != 8) return false;
    const long long size = Le32(h + 4);
    if (std::memcmp(h, "fmt ", 4) == 0) {
      unsigned char fmt[40] = {};
      const size_t n = static_cast<size_t>(std::min<long long>(size, 40));
      if (std::fread(fmt, 1, n, f) != n || n < 16) return false;
      format = Le16(fmt);
      *channels = Le16(fmt + 2);
      *rate = static_cast<int>(Le32(fmt + 4));
      bits = Le16(fmt + 14);
      if (format == 0xFFFE && n >= 26) format = Le16(fmt + 24);
    } else if (std::memcmp(h, "data", 4) == 0) {
      if (format != 1 || bits != 16 || *channels < 1 || *channels > 2 || *rate <= 0) return false;
      *data_offset = pos + 8;
      *data_bytes = std::min(size, length - pos - 8);
      return true;
    }
    pos += 8 + size + (size & 1);
  }
  return false;
}

}  // namespace

Mp4Encoder::~Mp4Encoder() { Cancel(); }

void Mp4Encoder::Caps(int* max_long, int* max_short) {
  *max_long = 4096;
  *max_short = 2304;
}

std::string Mp4Encoder::Start(int width, int height, int fps, int bitrate,
                              const std::wstring& audio_wav, const std::wstring& output) {
  Cancel();
  if (width <= 0 || height <= 0 || (width & 1) || (height & 1)) return "bad size";
  if (fps <= 0) return "bad frame rate";
  width_ = width;
  height_ = height;
  fps_ = fps;
  frames_ = 0;
  output_ = output;

  HRESULT hr = MFStartup(MF_VERSION);
  if (FAILED(hr)) return Hr("MFStartup", hr);
  mf_started_ = true;

  // The audio: a 16-bit PCM WAV, read as the frames go.
  long long data_offset = 0, data_bytes = 0;
  if (_wfopen_s(&wav_, audio_wav.c_str(), L"rb") != 0) wav_ = nullptr;
  if (wav_ == nullptr) {
    Cancel();
    return "the audio file can't be opened";
  }
  has_audio_ = ReadWav(wav_, &rate_, &channels_, &data_offset, &data_bytes);
  if (!has_audio_) {
    Cancel();
    return "the audio is not a 16-bit PCM WAV";
  }
  if (has_audio_) {
    if (rate_ != 44100 && rate_ != 48000) {
      Cancel();
      return "the AAC encoder takes 44.1 or 48 kHz";
    }
    audio_frames_total_ = data_bytes / (channels_ * 2);
    audio_frames_done_ = 0;
    _fseeki64(wav_, data_offset, SEEK_SET);
  }

  IMFAttributes* attrs = nullptr;
  IMFMediaType* out = nullptr;
  IMFMediaType* in = nullptr;
  std::string error;
  do {
    hr = MFCreateAttributes(&attrs, 2);
    if (FAILED(hr)) { error = Hr("MFCreateAttributes", hr); break; }
    attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    attrs->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
    hr = MFCreateSinkWriterFromURL(output.c_str(), nullptr, attrs, &writer_);
    if (FAILED(hr)) { error = Hr("MFCreateSinkWriterFromURL", hr); break; }

    // Video: H.264 out, NV12 in.
    hr = MFCreateMediaType(&out);
    if (FAILED(hr)) { error = Hr("MFCreateMediaType", hr); break; }
    out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    out->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(bitrate));
    out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(out, MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(out, MF_MT_FRAME_RATE, fps, 1);
    MFSetAttributeRatio(out, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    hr = writer_->AddStream(out, &video_stream_);
    if (FAILED(hr)) { error = Hr("AddStream (H.264)", hr); break; }
    hr = MFCreateMediaType(&in);
    if (FAILED(hr)) { error = Hr("MFCreateMediaType", hr); break; }
    in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(in, MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(in, MF_MT_FRAME_RATE, fps, 1);
    MFSetAttributeRatio(in, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    hr = writer_->SetInputMediaType(video_stream_, in, nullptr);
    if (FAILED(hr)) { error = Hr("SetInputMediaType (NV12)", hr); break; }
    SafeRelease(&out);
    SafeRelease(&in);

    if (has_audio_) {
      // Audio: AAC-LC at 160 kbit/s out, 16-bit PCM in.
      hr = MFCreateMediaType(&out);
      if (FAILED(hr)) { error = Hr("MFCreateMediaType", hr); break; }
      out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      out->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
      out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate_);
      out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels_);
      out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 20000);
      hr = writer_->AddStream(out, &audio_stream_);
      if (FAILED(hr)) { error = Hr("AddStream (AAC)", hr); break; }
      hr = MFCreateMediaType(&in);
      if (FAILED(hr)) { error = Hr("MFCreateMediaType", hr); break; }
      in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      in->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      in->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      in->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate_);
      in->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels_);
      in->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels_ * 2);
      in->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate_ * channels_ * 2);
      hr = writer_->SetInputMediaType(audio_stream_, in, nullptr);
      if (FAILED(hr)) { error = Hr("SetInputMediaType (PCM)", hr); break; }
    }
    hr = writer_->BeginWriting();
    if (FAILED(hr)) { error = Hr("BeginWriting", hr); break; }
  } while (false);
  SafeRelease(&attrs);
  SafeRelease(&out);
  SafeRelease(&in);
  if (!error.empty()) Cancel();
  return error;
}

std::string Mp4Encoder::AddFrame(const uint8_t* rgba, size_t size) {
  if (writer_ == nullptr) return "not started";
  const size_t w = static_cast<size_t>(width_), h = static_cast<size_t>(height_);
  if (size != w * h * 4) return "wrong frame size";
  const DWORD bytes = static_cast<DWORD>(w * h * 3 / 2);
  IMFMediaBuffer* buffer = nullptr;
  IMFSample* sample = nullptr;
  HRESULT hr = MFCreateMemoryBuffer(bytes, &buffer);
  if (FAILED(hr)) return Hr("MFCreateMemoryBuffer", hr);
  BYTE* dst = nullptr;
  hr = buffer->Lock(&dst, nullptr, nullptr);
  if (SUCCEEDED(hr)) {
    // RGBA (top row first) to NV12: a Y plane, then interleaved U and V at half size.
    for (size_t y = 0; y < h; ++y) {
      const uint8_t* s = rgba + y * w * 4;
      BYTE* d = dst + y * w;
      for (size_t x = 0; x < w; ++x, s += 4) {
        d[x] = static_cast<BYTE>(((66 * s[0] + 129 * s[1] + 25 * s[2] + 128) >> 8) + 16);
      }
    }
    BYTE* uv = dst + w * h;
    for (size_t y = 0; y < h / 2; ++y) {
      for (size_t x = 0; x < w / 2; ++x) {
        int r = 0, g = 0, b = 0;
        for (size_t dy = 0; dy < 2; ++dy) {
          for (size_t dx = 0; dx < 2; ++dx) {
            const uint8_t* p = rgba + ((y * 2 + dy) * w + x * 2 + dx) * 4;
            r += p[0];
            g += p[1];
            b += p[2];
          }
        }
        r >>= 2;
        g >>= 2;
        b >>= 2;
        uv[y * w + x * 2] = static_cast<BYTE>(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
        uv[y * w + x * 2 + 1] = static_cast<BYTE>(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
      }
    }
    buffer->Unlock();
    buffer->SetCurrentLength(bytes);
    hr = MFCreateSample(&sample);
  }
  if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer);
  const long long t = frames_ * 10000000LL / fps_;
  const long long next = (frames_ + 1) * 10000000LL / fps_;
  if (SUCCEEDED(hr)) hr = sample->SetSampleTime(t);
  if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(next - t);
  if (SUCCEEDED(hr)) hr = writer_->WriteSample(video_stream_, sample);
  SafeRelease(&sample);
  SafeRelease(&buffer);
  if (FAILED(hr)) return Hr("WriteSample (video)", hr);
  ++frames_;
  // The audio up to the end of this frame, so the two streams stay interleaved.
  return WriteAudioUntil(next);
}

std::string Mp4Encoder::WriteAudioUntil(long long time_100ns) {
  if (!has_audio_ || wav_ == nullptr) return std::string();
  const int block = channels_ * 2;
  std::vector<unsigned char> chunk;
  while (audio_frames_done_ < audio_frames_total_) {
    const long long at = audio_frames_done_ * 10000000LL / rate_;
    if (at >= time_100ns) break;
    const long long n = std::min<long long>(4096, audio_frames_total_ - audio_frames_done_);
    chunk.resize(static_cast<size_t>(n * block));
    const size_t got = std::fread(chunk.data(), 1, chunk.size(), wav_);
    const long long frames = static_cast<long long>(got) / block;
    if (frames <= 0) {
      audio_frames_done_ = audio_frames_total_;
      break;
    }
    IMFMediaBuffer* buffer = nullptr;
    IMFSample* sample = nullptr;
    HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(frames * block), &buffer);
    BYTE* dst = nullptr;
    if (SUCCEEDED(hr)) hr = buffer->Lock(&dst, nullptr, nullptr);
    if (SUCCEEDED(hr)) {
      std::memcpy(dst, chunk.data(), static_cast<size_t>(frames * block));
      buffer->Unlock();
      buffer->SetCurrentLength(static_cast<DWORD>(frames * block));
      hr = MFCreateSample(&sample);
    }
    if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer);
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(at);
    if (SUCCEEDED(hr)) hr = sample->SetSampleDuration((audio_frames_done_ + frames) * 10000000LL / rate_ - at);
    if (SUCCEEDED(hr)) hr = writer_->WriteSample(audio_stream_, sample);
    SafeRelease(&sample);
    SafeRelease(&buffer);
    if (FAILED(hr)) return Hr("WriteSample (audio)", hr);
    audio_frames_done_ += frames;
  }
  return std::string();
}

std::string Mp4Encoder::Finish() {
  if (writer_ == nullptr) return "not started";
  std::string error = WriteAudioUntil(0x7fffffffffffffffLL);
  if (error.empty()) {
    const HRESULT hr = writer_->Finalize();
    if (FAILED(hr)) error = Hr("Finalize", hr);
  }
  if (!error.empty()) {
    Cancel();
    return error;
  }
  Release();
  return std::string();
}

void Mp4Encoder::Release() {
  SafeRelease(&writer_);
  if (wav_ != nullptr) {
    std::fclose(wav_);
    wav_ = nullptr;
  }
  if (mf_started_) {
    MFShutdown();
    mf_started_ = false;
  }
}

void Mp4Encoder::Cancel() {
  const bool had_writer = writer_ != nullptr;
  Release();
  if (had_writer && !output_.empty()) ::DeleteFileW(output_.c_str());
}
