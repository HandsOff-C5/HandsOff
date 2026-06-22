#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <Speech/Speech.h>
#import <dispatch/dispatch.h>

typedef void (*HandsOffSttEventCallback)(const char *json);

typedef NS_ENUM(NSInteger, HandsOffSttEngine) {
  HandsOffSttEngineSFSpeechRecognizer = 1,
  HandsOffSttEngineSpeechAnalyzer = 2,
};

int handsoff_stt_engine_for_macos_major(int major_version, int speech_analyzer_compiled) {
  return (major_version >= 26 && speech_analyzer_compiled != 0) ? HandsOffSttEngineSpeechAnalyzer
                                                               : HandsOffSttEngineSFSpeechRecognizer;
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
static HandsOffSttEngine handsoff_selected_stt_engine(void) {
  NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
  return (HandsOffSttEngine)handsoff_stt_engine_for_macos_major((int)version.majorVersion,
                                                               1);
}

extern int handsoff_speechanalyzer_start(HandsOffSttEventCallback callback);
extern void handsoff_speechanalyzer_stop(void);
#endif

// Emit a typed native event as JSON. The Rust side parses into strongly-typed
// structs (see stt_ondevice.rs) that validate the structure and fail loudly on
// malformed input. Field names use snake_case to match Rust conventions.
static void handsoff_emit_stt_event(HandsOffSttEventCallback callback, NSDictionary *object) {
  if (callback == NULL || object == nil) {
    return;
  }

  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
  if (data == nil || error != nil) {
    return;
  }

  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (json == nil) {
    return;
  }

  callback([json UTF8String]);
}

API_AVAILABLE(macos(10.15))
static BOOL handsoff_stt_permissions_are_authorized(HandsOffSttEventCallback callback) {
  if ([SFSpeechRecognizer authorizationStatus] != SFSpeechRecognizerAuthorizationStatusAuthorized) {
    NSInteger status = (NSInteger)[SFSpeechRecognizer authorizationStatus];
    handsoff_emit_stt_event(callback, @{
      @"kind" : @"error",
      @"error_kind" : @"mic-permission",
      @"message" : @"speech recognition not authorized",
      @"permission_status" : @(status),
    });
    return NO;
  }

  if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
    NSInteger status = (NSInteger)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    handsoff_emit_stt_event(callback, @{
      @"kind" : @"error",
      @"error_kind" : @"mic-permission",
      @"message" : @"microphone access not authorized",
      @"permission_status" : @(status),
    });
    return NO;
  }

  return YES;
}

API_AVAILABLE(macos(10.15))
@interface HandsOffSttSession : NSObject
@property(nonatomic, assign) HandsOffSttEventCallback callback;
@property(nonatomic, strong) SFSpeechRecognizer *recognizer;
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property(nonatomic, strong) SFSpeechRecognitionTask *task;
@property(nonatomic, strong) NSDate *startedAt;
@property(nonatomic, assign) BOOL stopping;
- (instancetype)initWithCallback:(HandsOffSttEventCallback)callback;
- (void)start;
- (void)stop;
@end

static HandsOffSttSession *activeSttSession API_AVAILABLE(macos(10.15));

@implementation HandsOffSttSession

- (instancetype)initWithCallback:(HandsOffSttEventCallback)callback {
  self = [super init];
  if (self) {
    _callback = callback;
    _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
    _engine = [[AVAudioEngine alloc] init];
    _startedAt = [NSDate date];
  }
  return self;
}

- (void)emit:(NSDictionary *)object {
  handsoff_emit_stt_event(self.callback, object);
}

- (void)emitError:(NSString *)kind message:(NSString *)message {
  [self emit:@{
    @"kind" : @"error",
    @"error_kind" : kind,
    @"message" : message,
  }];
}

- (void)start {
  if (self.recognizer == nil) {
    [self emitError:@"provider-unavailable" message:@"no recognizer for current locale"];
    return;
  }

  if (!self.recognizer.available) {
    [self emitError:@"provider-unavailable" message:@"recognizer unavailable"];
    return;
  }

  SFSpeechAudioBufferRecognitionRequest *request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
  request.shouldReportPartialResults = YES;
  if (self.recognizer.supportsOnDeviceRecognition) {
    request.requiresOnDeviceRecognition = YES;
  }
  self.request = request;

  AVAudioInputNode *input = self.engine.inputNode;
  AVAudioFormat *format = [input outputFormatForBus:0];
  if (format.channelCount == 0) {
    [self emitError:@"start-failed" message:@"no microphone input channels available"];
    return;
  }

  [input installTapOnBus:0
              bufferSize:1024
                  format:format
                   block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                     (void)when;
                     [request appendAudioPCMBuffer:buffer];
                   }];

  [self.engine prepare];
  NSError *engineError = nil;
  if (![self.engine startAndReturnError:&engineError]) {
    [input removeTapOnBus:0];
    NSString *message = engineError.localizedDescription ?: @"audio engine failed to start";
    [self emitError:@"start-failed" message:message];
    return;
  }

  __weak HandsOffSttSession *weakSelf = self;
  self.task = [self.recognizer recognitionTaskWithRequest:request
                                            resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                                              HandsOffSttSession *strongSelf = weakSelf;
                                              if (strongSelf == nil) {
                                                return;
                                              }
                                              if (result != nil) {
                                                [strongSelf emitResult:result];
                                              }
                                              if (error != nil && !strongSelf.stopping) {
                                                NSString *message = error.localizedDescription ?: @"recognition failed";
                                                [strongSelf emitError:@"provider-unavailable" message:message];
                                                [strongSelf stop];
                                              }
                                            }];

  [self emit:@{@"kind" : @"ready"}];
}

- (void)emitResult:(SFSpeechRecognitionResult *)result {
  NSString *text = result.bestTranscription.formattedString ?: @"";
  if (result.final) {
    NSArray<SFTranscriptionSegment *> *segments = result.bestTranscription.segments;
    double confidence = 0;
    if (segments.count > 0) {
      for (SFTranscriptionSegment *segment in segments) {
        confidence += segment.confidence;
      }
      confidence = confidence / segments.count;
    }
    NSInteger latencyMs = (NSInteger)([[NSDate date] timeIntervalSinceDate:self.startedAt] * 1000);
    [self emit:@{
      @"kind" : @"final",
      @"text" : text,
      @"confidence" : @(confidence),
      @"latency_ms" : @(latencyMs),
    }];
  } else {
    [self emit:@{@"kind" : @"partial", @"text" : text}];
  }
}

- (void)stop {
  self.stopping = YES;
  @try {
    [self.engine.inputNode removeTapOnBus:0];
  } @catch (NSException *exception) {
    (void)exception;
  }
  if (self.engine.running) {
    [self.engine stop];
  }
  [self.request endAudio];
  [self.task cancel];
  self.task = nil;
  self.request = nil;
}

@end

int handsoff_speech_authorization_status(void) {
  if (@available(macOS 10.15, *)) {
    return (int)[SFSpeechRecognizer authorizationStatus];
  }
  return -1;
}

int handsoff_microphone_authorization_status(void) {
  if (@available(macOS 10.14, *)) {
    return (int)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
  }
  return -1;
}

static void wait_for(dispatch_semaphore_t semaphore) {
  while (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
}

int handsoff_request_speech_authorization(void) {
  if (@available(macOS 10.15, *)) {
    __block int result = handsoff_speech_authorization_status();
    if (result != SFSpeechRecognizerAuthorizationStatusNotDetermined) {
      return result;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
      result = (int)status;
      dispatch_semaphore_signal(semaphore);
    }];
    wait_for(semaphore);
    return result;
  }
  return -1;
}

int handsoff_request_microphone_authorization(void) {
  if (@available(macOS 10.14, *)) {
    __block int result = handsoff_microphone_authorization_status();
    if (result != AVAuthorizationStatusNotDetermined) {
      return result;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL granted) {
                               result = granted ? AVAuthorizationStatusAuthorized : AVAuthorizationStatusDenied;
                               dispatch_semaphore_signal(semaphore);
                             }];
    wait_for(semaphore);
    return result;
  }
  return -1;
}

int handsoff_stt_start(HandsOffSttEventCallback callback) {
  if (@available(macOS 10.15, *)) {
    if (callback == NULL) {
      return 0;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [activeSttSession stop];
      activeSttSession = nil;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
      handsoff_speechanalyzer_stop();
#endif
      if (!handsoff_stt_permissions_are_authorized(callback)) {
        return;
      }
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
      if (handsoff_selected_stt_engine() == HandsOffSttEngineSpeechAnalyzer) {
        if (@available(macOS 26.0, *)) {
          if (handsoff_speechanalyzer_start(callback) == 0) {
            handsoff_emit_stt_event(callback, @{
              @"kind" : @"error",
              @"error_kind" : @"start-failed",
              @"message" : @"SpeechAnalyzer failed to start",
            });
          }
          return;
        }
      }
#endif
      activeSttSession = [[HandsOffSttSession alloc] initWithCallback:callback];
      [activeSttSession start];
    });
    return 1;
  }
  handsoff_emit_stt_event(callback, @{
    @"kind" : @"error",
    @"errorKind" : @"provider-unavailable",
    @"message" : @"on-device speech recognition requires macOS 10.15 or newer",
  });
  return 0;
}

void handsoff_stt_stop(void) {
  if (@available(macOS 10.15, *)) {
    dispatch_block_t stop = ^{
      [activeSttSession stop];
      activeSttSession = nil;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
      handsoff_speechanalyzer_stop();
#endif
    };

    if ([NSThread isMainThread]) {
      stop();
    } else {
      dispatch_sync(dispatch_get_main_queue(), stop);
    }
  }
}
