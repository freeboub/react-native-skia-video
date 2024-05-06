#include "VideoCompositionFramesExtractorHostObject.h"

#import "AVAssetTrackUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

namespace RNSkiaVideo {

VideoCompositionFramesExtractorHostObject::
    VideoCompositionFramesExtractorHostObject(
        jsi::Runtime& runtime, std::shared_ptr<react::CallInvoker> callInvoker,
        jsi::Object jsComposition)
    : EventEmitter(runtime, callInvoker) {

  composition = VideoComposition::fromJS(runtime, jsComposition);

  auto queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  dispatch_async(queue, ^{
    this->init();
  });
}

VideoCompositionFramesExtractorHostObject::
    ~VideoCompositionFramesExtractorHostObject() {
  this->release();
}

std::vector<jsi::PropNameID>
VideoCompositionFramesExtractorHostObject::getPropertyNames(jsi::Runtime& rt) {
  std::vector<jsi::PropNameID> result;
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("play")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("pause")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("seekTo")));
  result.push_back(
      jsi::PropNameID::forUtf8(rt, std::string("decodeCompositionFrames")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("on")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("dispose")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("currentTime")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("isLooping")));
  result.push_back(jsi::PropNameID::forUtf8(rt, std::string("isPlaying")));
  return result;
}

jsi::Value VideoCompositionFramesExtractorHostObject::get(
    jsi::Runtime& runtime, const jsi::PropNameID& propNameId) {
  auto propName = propNameId.utf8(runtime);
  if (propName == "play") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "play"), 0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (!released || initialized) {
            play();
          }
          return jsi::Value::undefined();
        });
  } else if (propName == "pause") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "pause"), 0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (!released || initialized) {
            pause();
          }
          return jsi::Value::undefined();
        });
  } else if (propName == "seekTo") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "seekTo"), 1,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (!released || initialized) {
            seekTo(
                CMTimeMakeWithSeconds(arguments[1].asNumber(), NSEC_PER_SEC));
          }
          return jsi::Value::undefined();
        });
  } else if (propName == "decodeCompositionFrames") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "decodeCompositionFrames"),
        0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (released || !initialized) {
            return jsi::Object(runtime);
          }
          auto frames = jsi::Object(runtime);
          auto currentTime = getCurrentTime();
          if (CMTimeGetSeconds(currentTime) >= composition->duration) {
            emit("complete", jsi::Value::null());
            if (isLooping) {
              seekTo(kCMTimeZero);
              currentTime = kCMTimeZero;
            } else {
              isPlaying = false;
            }
          }

          for (const auto& entry : itemDecoders) {
            auto decoder = entry.second;
            decoder->advance(currentTime);
            auto frame = jsi::Object(runtime);

            auto buffer = decoder->getCurrentBuffer();
            auto dimensions = decoder->getFramesDimensions();
            if (buffer) {
              frame.setProperty(runtime, "width", jsi::Value(dimensions.width));
              frame.setProperty(runtime, "height",
                                jsi::Value(dimensions.height));
              frame.setProperty(runtime, "rotation",
                                jsi::Value(dimensions.rotation));
              frame.setProperty(
                  runtime, "buffer",
                  jsi::BigInt::fromUint64(runtime,
                                          reinterpret_cast<uintptr_t>(buffer)));
              frames.setProperty(runtime, entry.first.c_str(), frame);
            }
          }
          return frames;
        });
  } else if (propName == "on") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "on"), 2,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          if (!released || initialized) {
            return jsi::Function::createFromHostFunction(
                runtime, jsi::PropNameID::forAscii(runtime, "dispose"), 2,
                [](jsi::Runtime& runtime, const jsi::Value& thisValue,
                   const jsi::Value* arguments, size_t count) -> jsi::Value {
                  return jsi::Value::undefined();
                });
          }
          auto name = arguments[0].asString(runtime).utf8(runtime);
          auto handler = arguments[1].asObject(runtime).asFunction(runtime);
          return this->on(name, std::move(handler));
        });
  } else if (propName == "dispose") {
    return jsi::Function::createFromHostFunction(
        runtime, jsi::PropNameID::forAscii(runtime, "dispose"), 0,
        [this](jsi::Runtime& runtime, const jsi::Value& thisValue,
               const jsi::Value* arguments, size_t count) -> jsi::Value {
          this->release();
          return jsi::Value::undefined();
        });
  } else if (propName == "currentTime") {
    return jsi::Value(released ? 0 : CMTimeGetSeconds(getCurrentTime()));
  } else if (propName == "isLooping") {
    return jsi::Value(!released && isLooping);
  } else if (propName == "isPlaying") {
    return jsi::Value(!released && isPlaying);
  }
  return jsi::Value::undefined();
}

void VideoCompositionFramesExtractorHostObject::set(
    jsi::Runtime& runtime, const jsi::PropNameID& propNameId,
    const jsi::Value& value) {
  if (released) {
    return;
  }
  auto propName = propNameId.utf8(runtime);
  if (propName == "isLooping") {
    isLooping = value.asBool();
  }
}

void VideoCompositionFramesExtractorHostObject::init() {
  if (released) {
    return;
  }
  try {
    for (const auto item : composition->items) {
      itemDecoders[item->id] = new VideoCompositionItemDecoder(item);
    }
  } catch (NSError* error) {
    auto runtime = this->getRuntime();
    auto jsError = jsi::Object(*runtime);
    jsError.setProperty(*runtime, "message",
                        jsi::String::createFromUtf8(
                            *runtime, [[error description] UTF8String] ?: ""));
    jsError.setProperty(*runtime, "code", jsi::Value((double)[error code]));
    this->emit("error", jsi::Value(*runtime, jsError));
    return;
  }
  initialized = true;
  this->emit("ready", jsi::Value::null());
}

void VideoCompositionFramesExtractorHostObject::play() {
  if (released) {
    return;
  }
  startDate =
      [NSDate dateWithTimeIntervalSinceNow:-CMTimeGetSeconds(pausePosition)];
  pausePosition = kCMTimeZero;
  isPlaying = true;
}

void VideoCompositionFramesExtractorHostObject::pause() {
  if (released || !isPlaying) {
    return;
  }
  pausePosition = getCurrentTime();
  isPlaying = false;
}

void VideoCompositionFramesExtractorHostObject::seekTo(CMTime time) {
  if (isPlaying) {
    startDate = [NSDate dateWithTimeIntervalSinceNow:-CMTimeGetSeconds(time)];
  } else {
    pausePosition = time;
  }
  for (const auto& entry : itemDecoders) {
    entry.second->seekTo(time);
  }
}

CMTime VideoCompositionFramesExtractorHostObject::getCurrentTime() {
  if (released) {
    return kCMTimeZero;
  }
  if (isPlaying) {
    NSTimeInterval elapsedTime =
        [[NSDate date] timeIntervalSinceDate:startDate];
    return CMTimeMakeWithSeconds(elapsedTime, NSEC_PER_SEC);
  } else {
    return pausePosition;
  }
}

void VideoCompositionFramesExtractorHostObject::release() {
  if (!released) {
    released = true;
    for (const auto& entry : itemDecoders) {
      entry.second->release();
    }
    removeAllListeners();
  }
}

} // namespace RNSkiaVideo
