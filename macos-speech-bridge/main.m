#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

@interface MyReadSpeechRuntime : NSObject
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioPlayerNode *player;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *renderOrder;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<AVAudioPCMBuffer *> *> *buffers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, AVSpeechSynthesizer *> *renderers;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *completed;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *scheduledIdentifiers;
@property(nonatomic, strong) NSNumber *playingIdentifier;
@property(nonatomic) BOOL engineConfigured;
@property(nonatomic) BOOL holdPlayback;
@property(nonatomic) BOOL startDelayScheduled;
@property(nonatomic) NSUInteger warmupTarget;
@property(nonatomic) NSUInteger generationToken;
@end

@implementation MyReadSpeechRuntime

- (instancetype)init {
    self = [super init];
    if (self) {
        _renderOrder = [NSMutableArray array];
        _buffers = [NSMutableDictionary dictionary];
        _renderers = [NSMutableDictionary dictionary];
        _completed = [NSMutableSet set];
        _scheduledIdentifiers = [NSMutableArray array];
        _warmupTarget = 1;
    }
    return self;
}

- (void)emit:(NSString *)event id:(NSNumber *)identifier message:(NSString *)message
       voice:(AVSpeechSynthesisVoice *)voice rate:(NSNumber *)rate {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObject:event forKey:@"event"];
    if (identifier) payload[@"id"] = identifier;
    if (message) payload[@"message"] = message;
    if (voice) {
        payload[@"voice"] = voice.name;
        payload[@"language"] = voice.language;
    }
    if (rate) payload[@"rate"] = rate;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    NSMutableData *line = [data mutableCopy];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:line];
}

- (AVSpeechSynthesisVoice *)voiceNamed:(NSString *)requested {
    if (![requested isKindOfClass:[NSString class]] || requested.length == 0) return nil;
    NSArray<AVSpeechSynthesisVoice *> *voices = [AVSpeechSynthesisVoice speechVoices];
    for (AVSpeechSynthesisVoice *voice in voices) {
        if ([voice.identifier isEqualToString:requested]) return voice;
    }
    NSString *plain = [requested stringByReplacingOccurrencesOfString:@"\\s*\\((Enhanced|Premium)\\)\\s*$"
                                                            withString:@""
                                                               options:NSRegularExpressionSearch | NSCaseInsensitiveSearch
                                                                 range:NSMakeRange(0, requested.length)];
    AVSpeechSynthesisVoice *best = nil;
    for (AVSpeechSynthesisVoice *voice in voices) {
        BOOL match = [voice.name caseInsensitiveCompare:requested] == NSOrderedSame ||
                     [voice.name caseInsensitiveCompare:plain] == NSOrderedSame;
        if (match && (!best || voice.quality > best.quality)) best = voice;
    }
    return best;
}

- (float)rateForWordsPerMinute:(NSNumber *)wordsPerMinute {
    double requested = wordsPerMinute ? MAX(wordsPerMinute.doubleValue, 1.0) : 180.0;
    double scaled = AVSpeechUtteranceDefaultSpeechRate * requested / 180.0;
    return (float)MIN(MAX(scaled, AVSpeechUtteranceMinimumSpeechRate),
                      AVSpeechUtteranceMaximumSpeechRate);
}

- (AVAudioPCMBuffer *)copyBuffer:(AVAudioPCMBuffer *)source {
    AVAudioPCMBuffer *copy = [[AVAudioPCMBuffer alloc] initWithPCMFormat:source.format
                                                           frameCapacity:source.frameLength];
    copy.frameLength = source.frameLength;
    const AudioBufferList *sourceList = source.audioBufferList;
    AudioBufferList *copyList = copy.mutableAudioBufferList;
    for (UInt32 index = 0; index < sourceList->mNumberBuffers; index++) {
        copyList->mBuffers[index].mDataByteSize = sourceList->mBuffers[index].mDataByteSize;
        memcpy(copyList->mBuffers[index].mData, sourceList->mBuffers[index].mData,
               sourceList->mBuffers[index].mDataByteSize);
    }
    return copy;
}

- (BOOL)configureEngine:(AVAudioFormat *)format identifier:(NSNumber *)identifier {
    if (self.engineConfigured) return YES;
    @try {
        self.engine = [[AVAudioEngine alloc] init];
        self.player = [[AVAudioPlayerNode alloc] init];
        [self.engine attachNode:self.player];
        [self.engine connect:self.player to:self.engine.mainMixerNode format:format];
        [self.engine prepare];
    } @catch (NSException *exception) {
        [self emit:@"error" id:identifier message:exception.reason voice:nil rate:nil];
        return NO;
    }
    NSError *error = nil;
    if (![self.engine startAndReturnError:&error]) {
        [self emit:@"error" id:identifier message:error.localizedDescription voice:nil rate:nil];
        return NO;
    }
    self.engineConfigured = YES;
    return YES;
}

- (void)startPlaybackNow {
    if (self.playingIdentifier || self.scheduledIdentifiers.count == 0) return;
    self.playingIdentifier = self.scheduledIdentifiers.firstObject;
    [self emit:@"started" id:self.playingIdentifier message:nil voice:nil rate:nil];
    [self.player play];
}

- (void)beginPlaybackIfReady {
    if (self.holdPlayback || self.playingIdentifier || self.scheduledIdentifiers.count == 0) return;
    if (self.scheduledIdentifiers.count >= self.warmupTarget) {
        [self startPlaybackNow];
        return;
    }
    if (self.renderers.count == 0 && self.renderOrder.count == 0 && !self.startDelayScheduled) {
        self.startDelayScheduled = YES;
        NSUInteger token = self.generationToken;
        __weak MyReadSpeechRuntime *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MyReadSpeechRuntime *runtime = weakSelf;
            if (!runtime || token != runtime.generationToken) return;
            runtime.startDelayScheduled = NO;
            [runtime startPlaybackNow];
        });
    }
}

- (void)finishPlayback:(NSNumber *)identifier token:(NSUInteger)token {
    if (token != self.generationToken ||
        ![self.scheduledIdentifiers.firstObject isEqualToNumber:identifier]) return;
    [self.scheduledIdentifiers removeObjectAtIndex:0];
    [self emit:@"finished" id:identifier message:nil voice:nil rate:nil];
    self.playingIdentifier = nil;
    if (self.scheduledIdentifiers.count > 0) {
        self.playingIdentifier = self.scheduledIdentifiers.firstObject;
        [self emit:@"started" id:self.playingIdentifier message:nil voice:nil rate:nil];
    } else {
        [self beginPlaybackIfReady];
    }
}

- (void)scheduleBuffers:(NSArray<AVAudioPCMBuffer *> *)buffers identifier:(NSNumber *)identifier
                   token:(NSUInteger)token {
    if (buffers.count == 0 || ![self configureEngine:buffers.firstObject.format identifier:identifier]) {
        [self emit:@"error" id:identifier message:@"speech synthesis produced no audio" voice:nil rate:nil];
        return;
    }
    [self.scheduledIdentifiers addObject:identifier];
    for (NSUInteger index = 0; index < buffers.count; index++) {
        AVAudioPCMBuffer *buffer = buffers[index];
        if (index + 1 == buffers.count) {
            __weak MyReadSpeechRuntime *weakSelf = self;
            [self.player scheduleBuffer:buffer
                 completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
                      completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
                (void)type;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf finishPlayback:identifier token:token];
                });
            }];
        } else {
            [self.player scheduleBuffer:buffer completionHandler:nil];
        }
    }
}

- (void)flushCompletedInOrder:(NSUInteger)token {
    while (self.renderOrder.count > 0 && [self.completed containsObject:self.renderOrder.firstObject]) {
        NSNumber *identifier = self.renderOrder.firstObject;
        [self.renderOrder removeObjectAtIndex:0];
        [self.completed removeObject:identifier];
        NSArray<AVAudioPCMBuffer *> *utteranceBuffers = self.buffers[identifier];
        [self.buffers removeObjectForKey:identifier];
        [self scheduleBuffers:utteranceBuffers identifier:identifier token:token];
    }
    [self beginPlaybackIfReady];
}

- (void)receiveBuffer:(AVAudioPCMBuffer *)buffer identifier:(NSNumber *)identifier
                 token:(NSUInteger)token {
    if (token != self.generationToken || !self.buffers[identifier]) return;
    if (buffer && buffer.frameLength > 0) {
        [self.buffers[identifier] addObject:buffer];
        return;
    }
    [self.renderers removeObjectForKey:identifier];
    [self.completed addObject:identifier];
    [self flushCompletedInOrder:token];
}

- (BOOL)reserveIdentifier:(NSNumber *)identifier {
    if (!identifier || self.buffers[identifier]) {
        [self emit:@"error" id:identifier message:@"duplicate or missing queue id"
              voice:nil rate:nil];
        return NO;
    }
    [self.renderOrder addObject:identifier];
    self.buffers[identifier] = [NSMutableArray array];
    return YES;
}

- (void)enqueue:(NSDictionary *)command {
    NSNumber *identifier = command[@"id"];
    NSString *text = command[@"text"];
    if (![identifier isKindOfClass:[NSNumber class]] ||
        ![text isKindOfClass:[NSString class]] || text.length == 0) {
        [self emit:@"error" id:identifier message:@"enqueue requires id and non-empty text"
              voice:nil rate:nil];
        return;
    }
    AVSpeechSynthesisVoice *voice = [self voiceNamed:command[@"voice"]];
    NSNumber *rate = @([self rateForWordsPerMinute:command[@"rate"]]);
    NSNumber *requestedVolume = command[@"volume"];
    float volume = requestedVolume ? MIN(MAX(requestedVolume.floatValue, 0.0f), 1.0f) : 1.0f;
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
    utterance.voice = voice;
    utterance.rate = rate.floatValue;
    utterance.volume = volume;

    if (![self reserveIdentifier:identifier]) return;
    AVSpeechSynthesizer *renderer = [[AVSpeechSynthesizer alloc] init];
    self.renderers[identifier] = renderer;
    NSUInteger token = self.generationToken;
    __weak MyReadSpeechRuntime *weakSelf = self;
    [renderer writeUtterance:utterance toBufferCallback:^(AVAudioBuffer *audioBuffer) {
        AVAudioPCMBuffer *copy = nil;
        if ([audioBuffer isKindOfClass:[AVAudioPCMBuffer class]] &&
            ((AVAudioPCMBuffer *)audioBuffer).frameLength > 0) {
            copy = [weakSelf copyBuffer:(AVAudioPCMBuffer *)audioBuffer];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf receiveBuffer:copy identifier:identifier token:token];
        });
    }];
    [self emit:@"queued" id:identifier message:nil voice:voice rate:rate];
}

- (void)loadAudioFile:(NSDictionary *)command {
    NSNumber *identifier = command[@"id"];
    NSString *path = command[@"path"];
    if (![identifier isKindOfClass:[NSNumber class]] || !self.buffers[identifier] ||
        ![path isKindOfClass:[NSString class]] || path.length == 0) {
        [self emit:@"error" id:identifier message:@"loadFile requires a reserved id and path"
              voice:nil rate:nil];
        return;
    }
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path]
                                                     error:&error];
    if (!file || error) {
        [self emit:@"error" id:identifier message:error.localizedDescription voice:nil rate:nil];
        return;
    }
    AVAudioFrameCount capacity = (AVAudioFrameCount)file.length;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                             frameCapacity:capacity];
    if (![file readIntoBuffer:buffer error:&error] || error || buffer.frameLength == 0) {
        [self emit:@"error" id:identifier
            message:error.localizedDescription ?: @"audio file contained no frames"
              voice:nil rate:nil];
        return;
    }
    if (![self configureEngine:buffer.format identifier:identifier]) return;
    NSNumber *volume = command[@"volume"];
    if (volume) self.player.volume = MIN(MAX(volume.floatValue, 0.0f), 1.0f);
    [self.buffers[identifier] addObject:buffer];
    [self.completed addObject:identifier];
    [self emit:@"loaded" id:identifier message:nil voice:nil rate:nil];
    [self flushCompletedInOrder:self.generationToken];
}

- (void)discardIdentifier:(NSNumber *)identifier {
    AVSpeechSynthesizer *renderer = self.renderers[identifier];
    [renderer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [self.renderers removeObjectForKey:identifier];
    [self.renderOrder removeObject:identifier];
    [self.buffers removeObjectForKey:identifier];
    [self.completed removeObject:identifier];
    [self emit:@"cancelled" id:identifier message:nil voice:nil rate:nil];
    [self flushCompletedInOrder:self.generationToken];
}

- (void)stop {
    self.generationToken++;
    for (AVSpeechSynthesizer *renderer in self.renderers.allValues) {
        [renderer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    }
    [self.player stop];
    if (self.engineConfigured) {
        [self.engine stop];
        [self.engine disconnectNodeOutput:self.player];
        [self.engine detachNode:self.player];
        self.player = nil;
        self.engine = nil;
        self.engineConfigured = NO;
    }
    [self.renderOrder removeAllObjects];
    [self.buffers removeAllObjects];
    [self.renderers removeAllObjects];
    [self.completed removeAllObjects];
    [self.scheduledIdentifiers removeAllObjects];
    self.playingIdentifier = nil;
    self.holdPlayback = NO;
    self.startDelayScheduled = NO;
    self.warmupTarget = 1;
    [self emit:@"stopped" id:nil message:nil voice:nil rate:nil];
}

- (void)handleCommand:(NSDictionary *)command {
    NSString *name = command[@"command"];
    if ([name isEqualToString:@"enqueue"]) {
        [self enqueue:command];
    } else if ([name isEqualToString:@"reserve"]) {
        NSNumber *identifier = command[@"id"];
        if ([identifier isKindOfClass:[NSNumber class]] &&
            [self reserveIdentifier:identifier]) {
            [self emit:@"queued" id:identifier message:nil voice:nil rate:nil];
        }
    } else if ([name isEqualToString:@"loadFile"]) {
        [self loadAudioFile:command];
    } else if ([name isEqualToString:@"discard"]) {
        [self discardIdentifier:command[@"id"]];
    } else if ([name isEqualToString:@"hold"]) {
        self.holdPlayback = YES;
    } else if ([name isEqualToString:@"play"]) {
        self.holdPlayback = NO;
        self.warmupTarget = MAX(1, [command[@"warmup"] unsignedIntegerValue]);
        [self beginPlaybackIfReady];
    } else if ([name isEqualToString:@"stop"]) {
        [self stop];
    } else if ([name isEqualToString:@"ping"]) {
        [self emit:@"pong" id:nil message:nil voice:nil rate:nil];
    } else if ([name isEqualToString:@"voices"]) {
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (AVSpeechSynthesisVoice *voice in [AVSpeechSynthesisVoice speechVoices]) {
            [rows addObject:[NSString stringWithFormat:@"%@\t%@\t%@",
                             voice.name, voice.language, voice.identifier]];
        }
        [self emit:@"voices" id:nil message:[rows componentsJoinedByString:@"\n"] voice:nil rate:nil];
    } else {
        [self emit:@"error" id:command[@"id"]
            message:[NSString stringWithFormat:@"unknown command: %@", name ?: @"(nil)"]
              voice:nil rate:nil];
    }
}

@end


int main(void) {
    @autoreleasepool {
        MyReadSpeechRuntime *runtime = [[MyReadSpeechRuntime alloc] init];
        [[NSFileHandle fileHandleWithStandardOutput]
         writeData:[@"{\"event\":\"ready\"}\n" dataUsingEncoding:NSUTF8StringEncoding]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char *line = NULL;
            size_t capacity = 0;
            while (getline(&line, &capacity, stdin) >= 0) {
                @autoreleasepool {
                    NSData *data = [NSData dataWithBytes:line length:strlen(line)];
                    NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([command isKindOfClass:[NSDictionary class]]) {
                        dispatch_async(dispatch_get_main_queue(), ^{ [runtime handleCommand:command]; });
                    }
                }
            }
            free(line);
            dispatch_async(dispatch_get_main_queue(), ^{ exit(0); });
        });
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
