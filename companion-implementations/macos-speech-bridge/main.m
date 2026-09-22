#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

@interface MyReadSpeechRuntime : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, AVSpeechSynthesisVoice *> *voiceCache;
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioPlayerNode *player;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *renderOrder;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<AVAudioPCMBuffer *> *> *buffers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, AVSpeechSynthesizer *> *renderers;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *completed;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *outputPaths;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *scheduledIdentifiers;
@property(nonatomic, strong) NSNumber *playingIdentifier;
@property(nonatomic) BOOL engineConfigured;
@property(nonatomic) BOOL holdPlayback;
@property(nonatomic) BOOL startDelayScheduled;
@property(nonatomic) NSUInteger warmupTarget;
@property(nonatomic) NSUInteger generationToken;
@property(nonatomic, strong) NSData *dictionaryData;
@property(nonatomic, strong) NSArray<NSDictionary *> *dictionaryEntries;
@property(nonatomic, strong) NSString *dictionaryError;
@end

@implementation MyReadSpeechRuntime

- (instancetype)init {
    self = [super init];
    if (self) {
        _voiceCache = [NSMutableDictionary dictionary];
        _renderOrder = [NSMutableArray array];
        _buffers = [NSMutableDictionary dictionary];
        _renderers = [NSMutableDictionary dictionary];
        _completed = [NSMutableSet set];
        _outputPaths = [NSMutableDictionary dictionary];
        _scheduledIdentifiers = [NSMutableArray array];
        _warmupTarget = 1;
        [self reloadDictionary];
    }
    return self;
}

- (void)reloadDictionary {
    NSString *path = NSProcessInfo.processInfo.environment[@"READER_SPEECH_DICTIONARY"];
    if (!path.length) {
        NSString *root = NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath;
        for (NSUInteger level = 0; level < 3; level++) root = root.stringByDeletingLastPathComponent;
        path = [root stringByAppendingPathComponent:@"pronunciations.json"];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        self.dictionaryData = nil;
        self.dictionaryEntries = @[];
        self.dictionaryError = nil;
        return;
    }
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (data && [data isEqualToData:self.dictionaryData]) {
        self.dictionaryError = nil;
        return;
    }
    id root = data.length <= 2 * 1024 * 1024 && data ?
        [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    BOOL valid = [root isKindOfClass:[NSDictionary class]] &&
        [root[@"version"] isEqual:@1] && [root[@"entries"] isKindOfClass:[NSArray class]];
    if (valid) for (id entry in root[@"entries"]) {
        if (![entry isKindOfClass:[NSDictionary class]] ||
            ![entry[@"word"] isKindOfClass:[NSString class]] || ![entry[@"word"] length] ||
            ![entry[@"reading"] isKindOfClass:[NSString class]] || ![entry[@"reading"] length]) {
            valid = NO;
            break;
        }
    }
    if (!valid) {
        self.dictionaryError = error.localizedDescription ?: @"invalid pronunciation dictionary";
        return;
    }
    self.dictionaryData = data;
    self.dictionaryError = nil;
    self.dictionaryEntries = [root[@"entries"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger x = [a[@"word"] length], y = [b[@"word"] length];
        return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
    }];
}

- (NSMutableAttributedString *)pronouncedText:(NSString *)text voice:(AVSpeechSynthesisVoice *)voice {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    NSCharacterSet *latin = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    NSUInteger offset = 0;
    while (offset < text.length) {
        NSDictionary *match = nil;
        if ([voice.language hasPrefix:@"ja"]) for (NSDictionary *entry in self.dictionaryEntries) {
            NSString *word = entry[@"word"];
            if (word.length > text.length - offset ||
                ![[text substringWithRange:NSMakeRange(offset, word.length)] isEqualToString:word]) continue;
            if ([latin characterIsMember:[word characterAtIndex:0]] && offset &&
                [latin characterIsMember:[text characterAtIndex:offset - 1]]) continue;
            NSUInteger end = offset + word.length;
            if ([latin characterIsMember:[word characterAtIndex:word.length - 1]] && end < text.length &&
                [latin characterIsMember:[text characterAtIndex:end]]) continue;
            match = entry;
            break;
        }
        if (match) {
            BOOL ipa = [match[@"strategy"] isEqual:@"ipa"] && [match[@"ipa"] isKindOfClass:[NSString class]] &&
                [match[@"voice_identifier"] isEqual:voice.identifier] &&
                [match[@"os_version"] isEqual:NSProcessInfo.processInfo.operatingSystemVersionString];
            NSString *spoken = ipa ? match[@"word"] : match[@"reading"];
            if (!ipa) spoken = [spoken stringByApplyingTransform:NSStringTransformHiraganaToKatakana reverse:NO];
            NSDictionary *attributes = ipa ? @{AVSpeechSynthesisIPANotationAttribute: match[@"ipa"]} : @{};
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:spoken attributes:attributes]];
            offset += [match[@"word"] length];
        } else {
            NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:offset];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringWithRange:range]]];
            offset = NSMaxRange(range);
        }
    }
    return result;
}

- (void)emit:(NSString *)event id:(NSNumber *)identifier message:(NSString *)message
       voice:(AVSpeechSynthesisVoice *)voice rate:(NSNumber *)rate {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObject:event forKey:@"event"];
    if (identifier) payload[@"id"] = identifier;
    if (message) payload[@"message"] = message;
    if (voice) {
        payload[@"voice"] = voice.name;
        payload[@"language"] = voice.language;
        payload[@"voiceIdentifier"] = voice.identifier;
        payload[@"osVersion"] = NSProcessInfo.processInfo.operatingSystemVersionString;
    }
    if (rate) payload[@"rate"] = rate;
    [self writeEvent:payload];
}

- (void)emitLoaded:(NSNumber *)identifier buffers:(NSArray<AVAudioPCMBuffer *> *)buffers {
    double duration = 0;
    for (AVAudioPCMBuffer *buffer in buffers) {
        duration += buffer.frameLength / buffer.format.sampleRate;
    }
    [self writeEvent:@{@"event": @"loaded", @"id": identifier, @"duration": @(duration)}];
}

- (void)writeEvent:(NSDictionary *)payload {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    NSMutableData *line = [data mutableCopy];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:line];
}

- (AVSpeechSynthesisVoice *)voiceNamed:(NSString *)requested {
    if (![requested isKindOfClass:[NSString class]] || requested.length == 0) return nil;
    // Voice enumeration can block inside macOS TextToSpeech.  Resolve each
    // requested voice once for this resident process, not once per chunk.
    AVSpeechSynthesisVoice *cached = self.voiceCache[requested];
    if (cached) return cached;
    NSArray<AVSpeechSynthesisVoice *> *voices = [AVSpeechSynthesisVoice speechVoices];
    for (AVSpeechSynthesisVoice *voice in voices) {
        if ([voice.identifier isEqualToString:requested]) {
            self.voiceCache[requested] = voice;
            return voice;
        }
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
    if (best) self.voiceCache[requested] = best;
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
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
        if (@available(macOS 27.0, *)) {
            NSError *connectionError = nil;
            if (![self.engine connect:self.player to:self.engine.mainMixerNode format:format error:&connectionError]) {
                [self emit:@"error" id:identifier message:connectionError.localizedDescription voice:nil rate:nil];
                return NO;
            }
        } else
#endif
        {
            [self.engine connect:self.player to:self.engine.mainMixerNode format:format];
        }
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
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
    if (@available(macOS 27.0, *)) {
        NSError *error = nil;
        if (![self.player playAndReturnError:&error]) {
            [self emit:@"error" id:self.playingIdentifier message:error.localizedDescription voice:nil rate:nil];
            self.playingIdentifier = nil;
        }
    } else
#endif
    {
        [self.player play];
    }
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
        // A starved player remains running. Pause before scheduling late audio,
        // otherwise it plays before warmup release and its "started" event.
        [self.player pause];
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
    NSString *output = self.outputPaths[identifier];
    if (output) {
        NSArray<AVAudioPCMBuffer *> *chunks = self.buffers[identifier];
        NSError *error = nil;
        @autoreleasepool {
            AVAudioFile *file = chunks.count ? [[AVAudioFile alloc]
                initForWriting:[NSURL fileURLWithPath:output]
                settings:chunks.firstObject.format.settings error:&error] : nil;
            for (AVAudioPCMBuffer *chunk in chunks) {
                if (!file || ![file writeFromBuffer:chunk error:&error]) break;
            }
        }
        [self emit:(!chunks.count || error) ? @"error" : @"rendered" id:identifier
            message:error.localizedDescription ?: (!chunks.count ? @"speech synthesis produced no audio" : nil)
            voice:nil rate:nil];
        [self.outputPaths removeObjectForKey:identifier];
        [self.buffers removeObjectForKey:identifier];
        [self.renderOrder removeObject:identifier];
        [self flushCompletedInOrder:token];
        return;
    }
    [self emitLoaded:identifier buffers:self.buffers[identifier]];
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
    if (!voice) {
        [self emit:@"error" id:identifier message:@"requested voice is unavailable" voice:nil rate:nil];
        return;
    }
    NSNumber *rate = @([self rateForWordsPerMinute:command[@"rate"]]);
    NSNumber *requestedVolume = command[@"volume"];
    float volume = requestedVolume ? MIN(MAX(requestedVolume.floatValue, 0.0f), 1.0f) : 1.0f;
    [self reloadDictionary];
    BOOL useDictionary = !command[@"useDictionary"] || [command[@"useDictionary"] boolValue];
    if (useDictionary && self.dictionaryError) {
        [self emit:@"error" id:identifier message:self.dictionaryError voice:nil rate:nil];
        return;
    }
    NSMutableAttributedString *attributed = useDictionary ? [self pronouncedText:text voice:voice] :
        [[NSMutableAttributedString alloc] initWithString:text];
    // Explicit spans are used by the local pronunciation capability probe.
    for (NSDictionary *span in command[@"ipaSpans"]) {
        NSUInteger location = [span[@"location"] unsignedIntegerValue];
        NSUInteger length = [span[@"length"] unsignedIntegerValue];
        if (location <= attributed.length && length <= attributed.length - location &&
            [span[@"ipa"] isKindOfClass:[NSString class]]) {
            [attributed addAttribute:AVSpeechSynthesisIPANotationAttribute value:span[@"ipa"]
                range:NSMakeRange(location, length)];
        }
    }
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithAttributedString:attributed];
    utterance.voice = voice;
    utterance.rate = rate.floatValue;
    utterance.volume = volume;

    if (![self reserveIdentifier:identifier]) return;
    if ([command[@"command"] isEqualToString:@"render"]) {
        NSString *path = command[@"path"];
        if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath) {
            [self discardIdentifier:identifier];
            [self emit:@"error" id:identifier message:@"render requires an absolute output path" voice:nil rate:nil];
            return;
        }
        self.outputPaths[identifier] = path;
    }
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
    [self emitLoaded:identifier buffers:@[buffer]];
    [self flushCompletedInOrder:self.generationToken];
}

- (void)discardIdentifier:(NSNumber *)identifier {
    AVSpeechSynthesizer *renderer = self.renderers[identifier];
    [renderer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [self.renderers removeObjectForKey:identifier];
    [self.renderOrder removeObject:identifier];
    [self.buffers removeObjectForKey:identifier];
    [self.completed removeObject:identifier];
    [self.outputPaths removeObjectForKey:identifier];
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
    [self.outputPaths removeAllObjects];
    [self.scheduledIdentifiers removeAllObjects];
    self.playingIdentifier = nil;
    self.holdPlayback = NO;
    self.startDelayScheduled = NO;
    self.warmupTarget = 1;
    [self emit:@"stopped" id:nil message:nil voice:nil rate:nil];
}

- (void)handleCommand:(NSDictionary *)command {
    NSString *name = command[@"command"];
    if ([name isEqualToString:@"enqueue"] || [name isEqualToString:@"render"]) {
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
    } else if ([name isEqualToString:@"describeVoice"]) {
        AVSpeechSynthesisVoice *voice = [self voiceNamed:command[@"voice"]];
        [self emit:voice ? @"voice" : @"error" id:command[@"id"]
            message:voice ? nil : @"requested voice is unavailable" voice:voice rate:nil];
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
