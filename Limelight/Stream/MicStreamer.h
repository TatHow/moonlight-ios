//
//  MicStreamer.h
//  Moonlight
//
//  Fold build: sends this device's microphone to the host while streaming.
//  Apollo (fold branch) receives it on the session's audio port and plays it
//  into a virtual microphone on the PC (see src/mic_stream.h there).
//
//  Packet: 'M' 'I' 'C' 0x01 | seq (u32 LE) | AES-GCM tag (16) | AES-128-GCM(Opus frame)
//  Key: the session's remote input key. IV: seq LE in bytes 0..3, zeros, 'C' 'M' in bytes 10..11.
//  Opus: 48 kHz mono, 20 ms frames.
//
//  Header-only so it needs no project file changes; include it from Connection.m only.
//

#import <AVFoundation/AVFoundation.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <openssl/evp.h>
#include "opus.h"

#import "../ViewControllers/FoldDisplayMatch.h"

#define MIC_SAMPLE_RATE 48000
#define MIC_FRAME_SAMPLES 960   // 20 ms
#define MIC_MAX_OPUS 400

#if !TARGET_OS_TV

// Owns the encoder, cipher and socket for one capture run. The tap block
// holds a strong reference, so these stay valid until the block is gone.
@interface MicSender : NSObject
@end

@implementation MicSender {
    OpusEncoder* _encoder;
    EVP_CIPHER_CTX* _cipher;
    unsigned char _key[16];
    int _socket;
    struct sockaddr_storage _addr;
    socklen_t _addrLen;
    uint32_t _seq;
    int16_t _pending[MIC_FRAME_SAMPLES * 8];
    int _pendingCount;
}

- (instancetype) initWithAddress:(const struct sockaddr_storage*)addr length:(socklen_t)len key:(NSData*)key {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _socket = -1;
    if (key.length != 16) {
        return nil;
    }
    
    int err = 0;
    _encoder = opus_encoder_create(MIC_SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &err);
    if (_encoder == NULL) {
        Log(LOG_E, @"Mic: couldn't create Opus encoder: %d", err);
        return nil;
    }
    opus_encoder_ctl(_encoder, OPUS_SET_BITRATE(48000));
    opus_encoder_ctl(_encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    
    _cipher = EVP_CIPHER_CTX_new();
    if (_cipher == NULL ||
        EVP_EncryptInit_ex(_cipher, EVP_aes_128_gcm(), NULL, NULL, NULL) != 1 ||
        EVP_CIPHER_CTX_ctrl(_cipher, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1) {
        Log(LOG_E, @"Mic: couldn't set up encryption");
        return nil;
    }
    memcpy(_key, key.bytes, 16);
    
    memcpy(&_addr, addr, sizeof(_addr));
    _addrLen = len;
    _socket = socket(addr->ss_family, SOCK_DGRAM, IPPROTO_UDP);
    if (_socket < 0) {
        Log(LOG_E, @"Mic: couldn't create socket: %d", errno);
        return nil;
    }
    int tos = 0xB8; // EF, same priority as voice
    if (addr->ss_family == AF_INET) {
        setsockopt(_socket, IPPROTO_IP, IP_TOS, &tos, sizeof(tos));
    }
    
    // Different sessions get different keys, so starting at 0 never reuses an IV
    _seq = 0;
    return self;
}

- (void) dealloc {
    if (_encoder != NULL) {
        opus_encoder_destroy(_encoder);
    }
    if (_cipher != NULL) {
        EVP_CIPHER_CTX_free(_cipher);
    }
    if (_socket >= 0) {
        close(_socket);
    }
}

- (void) sendFrame:(const int16_t*)pcm {
    unsigned char opus[MIC_MAX_OPUS];
    int len = opus_encode(_encoder, pcm, MIC_FRAME_SAMPLES, opus, sizeof(opus));
    if (len <= 0) {
        return;
    }
    
    uint32_t seq = _seq++;
    unsigned char packet[4 + 4 + 16 + MIC_MAX_OPUS];
    packet[0] = 'M'; packet[1] = 'I'; packet[2] = 'C'; packet[3] = 0x01;
    uint32_t seqLE = CFSwapInt32HostToLittle(seq);
    memcpy(&packet[4], &seqLE, 4);
    
    unsigned char iv[12] = {0};
    memcpy(iv, &seqLE, 4);
    iv[10] = 'C'; // Client originated
    iv[11] = 'M'; // Microphone stream
    
    int outLen = 0, finalLen = 0;
    if (EVP_EncryptInit_ex(_cipher, NULL, NULL, _key, iv) != 1 ||
        EVP_EncryptUpdate(_cipher, &packet[24], &outLen, opus, len) != 1 ||
        EVP_EncryptFinal_ex(_cipher, &packet[24] + outLen, &finalLen) != 1 ||
        EVP_CIPHER_CTX_ctrl(_cipher, EVP_CTRL_GCM_GET_TAG, 16, &packet[8]) != 1) {
        return;
    }
    
    sendto(_socket, packet, 24 + outLen + finalLen, 0, (struct sockaddr*)&_addr, _addrLen);
}

- (void) sendPCM:(const int16_t*)pcm frames:(int)frames {
    while (frames > 0) {
        int take = MIN(frames, MIC_FRAME_SAMPLES - _pendingCount);
        memcpy(&_pending[_pendingCount], pcm, take * sizeof(int16_t));
        _pendingCount += take;
        pcm += take;
        frames -= take;
        if (_pendingCount == MIC_FRAME_SAMPLES) {
            [self sendFrame:_pending];
            _pendingCount = 0;
        }
    }
}

@end

#endif

@interface MicStreamer : NSObject
+ (instancetype) shared;
// Called when a stream connects; captures only while the mic setting is on
- (void) startWithAddress:(const struct sockaddr_storage*)addr length:(socklen_t)len port:(uint16_t)port key:(NSData*)key;
// Called when the stream ends
- (void) stop;
// The audio session category the stream should use for the current setting
+ (void) applyAudioSessionCategory;
@end

#if TARGET_OS_TV

// No microphone on Apple TV
@implementation MicStreamer

+ (instancetype) shared {
    static MicStreamer* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[MicStreamer alloc] init];
    });
    return shared;
}

+ (void) applyAudioSessionCategory {
    // Disable lowering volume of other audio streams (SDL sets AVAudioSessionCategoryOptionDuckOthers by default)
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
}

- (void) startWithAddress:(const struct sockaddr_storage*)addr length:(socklen_t)len port:(uint16_t)port key:(NSData*)key {
}

- (void) stop {
}

@end

#else

@implementation MicStreamer {
    dispatch_queue_t _queue;
    BOOL _streaming;
    struct sockaddr_storage _addr;
    socklen_t _addrLen;
    NSData* _key;
    
    AVAudioEngine* _engine;
    MicSender* _sender;
    id _configObserver;
}

+ (instancetype) shared {
    static MicStreamer* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[MicStreamer alloc] init];
    });
    return shared;
}

- (instancetype) init {
    self = [super init];
    _queue = dispatch_queue_create("MicStreamer", DISPATCH_QUEUE_SERIAL);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingChanged) name:kFoldMicSettingChangedNotification object:nil];
    return self;
}

+ (void) applyAudioSessionCategory {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSError* error = nil;
    if (FoldMicEnabled()) {
        // AllowBluetooth lets AirPods and other headsets be used as the mic (hands-free profile)
        AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionMixWithOthers |
                                                AVAudioSessionCategoryOptionAllowBluetooth |
                                                AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                                AVAudioSessionCategoryOptionDefaultToSpeaker;
        if (![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord] || session.categoryOptions != options) {
            [session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:options error:&error];
        }
    }
    else {
        // Disable lowering volume of other audio streams (SDL sets AVAudioSessionCategoryOptionDuckOthers by default)
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    }
    if (error != nil) {
        Log(LOG_W, @"Mic: couldn't set audio session category: %@", error);
    }
}

- (void) startWithAddress:(const struct sockaddr_storage*)addr length:(socklen_t)len port:(uint16_t)port key:(NSData*)key {
    struct sockaddr_storage target;
    memcpy(&target, addr, sizeof(target));
    if (target.ss_family == AF_INET6) {
        ((struct sockaddr_in6*)&target)->sin6_port = htons(port);
    }
    else {
        ((struct sockaddr_in*)&target)->sin_port = htons(port);
    }
    
    dispatch_async(_queue, ^{
        self->_addr = target;
        self->_addrLen = len;
        self->_key = key;
        self->_streaming = YES;
        [self updateCapture];
    });
}

- (void) stop {
    dispatch_sync(_queue, ^{
        self->_streaming = NO;
        [self stopCapture];
    });
}

- (void) settingChanged {
    dispatch_async(_queue, ^{
        if (self->_streaming) {
            [MicStreamer applyAudioSessionCategory];
        }
        [self updateCapture];
    });
}

// On _queue
- (void) updateCapture {
    BOOL want = _streaming && FoldMicEnabled();
    if (want && _engine == nil) {
        [self startCapture];
    }
    else if (!want && _engine != nil) {
        [self stopCapture];
    }
}

// On _queue
- (void) startCapture {
    AVAudioSessionRecordPermission permission = [[AVAudioSession sharedInstance] recordPermission];
    if (permission != AVAudioSessionRecordPermissionGranted) {
        Log(LOG_W, @"Mic: no microphone permission, not sending");
        return;
    }
    
    [MicStreamer applyAudioSessionCategory];
    
    MicSender* sender = [[MicSender alloc] initWithAddress:&_addr length:_addrLen key:_key];
    if (sender == nil) {
        return;
    }
    
    AVAudioEngine* engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode* input = engine.inputNode;
    AVAudioFormat* inputFormat = [input outputFormatForBus:0];
    if (inputFormat.sampleRate <= 0 || inputFormat.channelCount == 0) {
        Log(LOG_E, @"Mic: no input available");
        return;
    }
    
    AVAudioFormat* outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                   sampleRate:MIC_SAMPLE_RATE
                                                                     channels:1
                                                                  interleaved:YES];
    AVAudioConverter* converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    if (converter == nil) {
        Log(LOG_E, @"Mic: can't convert from %@", inputFormat);
        return;
    }
    
    double ratio = MIC_SAMPLE_RATE / inputFormat.sampleRate;
    [input installTapOnBus:0 bufferSize:(AVAudioFrameCount)(inputFormat.sampleRate / 50) format:inputFormat block:^(AVAudioPCMBuffer* buffer, AVAudioTime* when) {
        AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(buffer.frameLength * ratio) + 32;
        AVAudioPCMBuffer* out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:capacity];
        __block BOOL consumed = NO;
        NSError* error = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:out error:&error withInputFromBlock:^AVAudioBuffer*(AVAudioPacketCount count, AVAudioConverterInputStatus* inputStatus) {
            if (consumed) {
                *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            consumed = YES;
            *inputStatus = AVAudioConverterInputStatus_HaveData;
            return buffer;
        }];
        if (status != AVAudioConverterOutputStatus_Error && out.frameLength > 0) {
            [sender sendPCM:out.int16ChannelData[0] frames:(int)out.frameLength];
        }
    }];
    
    [engine prepare];
    NSError* error = nil;
    if (![engine startAndReturnError:&error]) {
        Log(LOG_E, @"Mic: couldn't start capture: %@", error);
        [input removeTapOnBus:0];
        return;
    }
    
    _engine = engine;
    _sender = sender;
    
    // The input format changes when AirPods or a headset connect or disconnect
    __weak MicStreamer* weakSelf = self;
    _configObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification
                                                                        object:engine
                                                                         queue:nil
                                                                    usingBlock:^(NSNotification* note) {
        MicStreamer* strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_async(strongSelf->_queue, ^{
            Log(LOG_I, @"Mic: audio route changed, restarting capture");
            [strongSelf stopCapture];
            [strongSelf updateCapture];
        });
    }];
    
    Log(LOG_I, @"Mic: sending %@ to the host", inputFormat);
}

// On _queue
- (void) stopCapture {
    if (_configObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:_configObserver];
        _configObserver = nil;
    }
    if (_engine != nil) {
        [_engine.inputNode removeTapOnBus:0];
        [_engine stop];
        _engine = nil;
        Log(LOG_I, @"Mic: stopped");
    }
    _sender = nil;
}

@end

#endif
