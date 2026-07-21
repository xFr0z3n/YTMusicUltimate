#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>

// Placeholders — substituted by GitHub Actions at build time, never commit real values
// NOTE: semantics changed in this revision:
//   kNextcloudWebDAVURL  = WebDAV *folder* URL, MUST end with a trailing slash
//                          e.g. https://cloud.example.com/remote.php/dav/files/USER/discord-art/
//   kNextcloudPublicURL  = public *folder share* base URL, NO trailing slash
//                          e.g. https://cloud.example.com/s/AbCdEfGhIjKlmNo
static NSString * const kDiscordToken       = @"__DISCORD_TOKEN__";
static NSString * const kDiscordAppID       = @"__DISCORD_APP_ID__";
static NSString * const kNextcloudWebDAVURL = @"__NEXTCLOUD_WEBDAV_URL__";
static NSString * const kNextcloudUser      = @"__NEXTCLOUD_USER__";
static NSString * const kNextcloudPass      = @"__NEXTCLOUD_PASS__";
static NSString * const kNextcloudPublicURL = @"__NEXTCLOUD_PUBLIC_URL__";

// Asset-key cache (trackKey -> mp: key), persisted across launches
static NSString * const kAssetCacheDefaultsKey = @"YTMUAssetKeyCache";
static const NSTimeInterval kAssetCacheTTL = 24 * 60 * 60; // 24h, then re-register
static const NSUInteger kAssetCacheMaxEntries = 300;

// Shared presence state — mutated only on the main queue
static NSString *gTrackTitle = nil;
static NSString *gTrackArtist = nil;
static NSString *gTrackAlbum = nil;
static double gTrackDuration = 0;
static NSTimeInterval gTrackStartEpoch = 0;
static NSString *gTrackImageKey = nil;
static BOOL gPresenceActive = NO;
static NSString *gLastTrackKey = nil;
static NSInteger gClearToken = 0;
static NSInteger gArtToken = 0;   // debounce token for artwork uploads
static UIImage *gPendingArtwork = nil;
static NSTimeInterval gLastScrubPush = 0; // throttle for scrub re-pushes

static void YTMUPushPresence(void);

#pragma mark - Small helpers

// Stable short hash for per-track artwork filenames
static NSString *YTMUHashKey(NSString *s) {
    const char *cstr = s.UTF8String ?: "";
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSMutableDictionary *YTMUAssetCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAssetCacheDefaultsKey];
        cache = [stored isKindOfClass:[NSDictionary class]] ? [stored mutableCopy] : [NSMutableDictionary new];
    });
    return cache;
}

// Returns a cached mp: key for this track, or nil if absent/expired
static NSString *YTMUCachedAssetKey(NSString *trackKey) {
    NSDictionary *entry = YTMUAssetCache()[trackKey];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSTimeInterval ts = [entry[@"ts"] doubleValue];
    if ([[NSDate date] timeIntervalSince1970] - ts > kAssetCacheTTL) return nil;
    NSString *key = entry[@"key"];
    return [key isKindOfClass:[NSString class]] ? key : nil;
}

static void YTMUStoreAssetKey(NSString *trackKey, NSString *assetKey) {
    if (!trackKey.length || !assetKey.length) return;
    NSMutableDictionary *cache = YTMUAssetCache();
    cache[trackKey] = @{ @"key": assetKey, @"ts": @([[NSDate date] timeIntervalSince1970]) };
    if (cache.count > kAssetCacheMaxEntries) {
        NSArray *oldestFirst = [cache keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [(NSNumber *)a[@"ts"] compare:(NSNumber *)b[@"ts"]];
        }];
        NSUInteger overflow = cache.count - kAssetCacheMaxEntries;
        for (NSString *k in [oldestFirst subarrayWithRange:NSMakeRange(0, overflow)]) {
            [cache removeObjectForKey:k];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:cache forKey:kAssetCacheDefaultsKey];
}

#pragma mark - Gateway client

@interface YTMUDiscordGateway : NSObject <NSURLSessionWebSocketDelegate>
+ (instancetype)shared;
- (void)connect;
- (void)sendActivityTitle:(NSString *)title
                   artist:(NSString *)artist
                    album:(NSString *)album
                 imageKey:(NSString *)imageKey
              durationSec:(double)durationSec
               startEpoch:(NSTimeInterval)startEpoch;
- (void)clearPresence;
@property (nonatomic, readonly) BOOL identified;
@end

@implementation YTMUDiscordGateway {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_socket;
    dispatch_source_t _heartbeatTimer;
    NSInteger _sequence;
    BOOL _identified;
    BOOL _connecting;
    // RESUME state
    NSString *_sessionID;
    NSString *_resumeURL;
    BOOL _resuming;
    // reconnect / liveness
    BOOL _awaitingAck;
    NSInteger _reconnectAttempts;
    BOOL _reconnectScheduled;
}

- (BOOL)identified { return _identified; }

+ (instancetype)shared {
    static YTMUDiscordGateway *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [YTMUDiscordGateway new]; });
    return instance;
}

- (void)connect {
    if (_socket || _connecting) return;
    _connecting = YES;
    _identified = NO;
    _awaitingAck = NO;
    _resuming = (_sessionID.length > 0 && _resumeURL.length > 0);
    if (!_resuming) _sequence = 0;

    NSString *urlStr;
    if (_resuming) {
        NSString *base = [_resumeURL hasSuffix:@"/"] ? _resumeURL : [_resumeURL stringByAppendingString:@"/"];
        urlStr = [NSString stringWithFormat:@"%@?v=10&encoding=json", base];
        NSLog(@"[YTMU] gateway connecting (resume)");
    } else {
        urlStr = @"wss://gateway.discord.gg/?v=10&encoding=json";
        NSLog(@"[YTMU] gateway connecting (fresh)");
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    // Delegate + completion handlers on the main queue -> all gateway state is main-queue-only
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    _socket = [_session webSocketTaskWithURL:[NSURL URLWithString:urlStr]];
    _socket.maximumMessageSize = 16 * 1024 * 1024;
    [_socket resume];
    [self receiveLoop];
}

- (void)receiveLoop {
    __weak typeof(self) weakSelf = self;
    [_socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            NSLog(@"[YTMU] gateway receive error: %@", error.localizedDescription);
            [self teardownKeepingSession:YES];
            [self scheduleReconnectWithBackoff];
            return;
        }
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [self handlePayload:payload];
        }
        [self receiveLoop];
    }];
}

- (void)handlePayload:(NSDictionary *)payload {
    if (!payload) return;
    if (payload[@"s"] && payload[@"s"] != [NSNull null]) {
        _sequence = [payload[@"s"] integerValue];
    }
    int op = [payload[@"op"] intValue];

    switch (op) {
        case 10: { // HELLO
            NSLog(@"[YTMU] gateway HELLO");
            NSDictionary *d = payload[@"d"];
            NSTimeInterval interval = [d[@"heartbeat_interval"] doubleValue] / 1000.0;
            [self startHeartbeat:interval];
            if (_resuming) [self sendResume];
            else [self identify];
            break;
        }
        case 0: { // DISPATCH
            NSString *t = payload[@"t"];
            if ([t isEqualToString:@"READY"]) {
                NSDictionary *d = payload[@"d"];
                NSString *sid = d[@"session_id"];
                NSString *rurl = d[@"resume_gateway_url"];
                if ([sid isKindOfClass:[NSString class]]) _sessionID = sid;
                if ([rurl isKindOfClass:[NSString class]]) _resumeURL = rurl;
                NSLog(@"[YTMU] gateway READY (session stored)");
                [self markLive];
            } else if ([t isEqualToString:@"RESUMED"]) {
                NSLog(@"[YTMU] gateway RESUMED");
                [self markLive];
            }
            break;
        }
        case 1: // heartbeat request
            [self sendHeartbeatRaw];
            break;
        case 11: // heartbeat ACK
            _awaitingAck = NO;
            break;
        case 7: // RECONNECT — server asks us to resume elsewhere
            NSLog(@"[YTMU] gateway RECONNECT requested");
            [self teardownKeepingSession:YES];
            [self scheduleReconnectAfter:0.5];
            break;
        case 9: { // INVALID SESSION — d:true means still resumable
            BOOL resumable = [payload[@"d"] boolValue];
            NSLog(@"[YTMU] gateway INVALID SESSION (resumable=%d)", resumable);
            [self teardownKeepingSession:resumable];
            // Discord docs: wait a short randomized delay before re-identifying
            [self scheduleReconnectAfter:2.0 + arc4random_uniform(3)];
            break;
        }
        default:
            break;
    }
}

- (void)markLive {
    _identified = YES;
    _connecting = NO;
    _resuming = NO;
    _reconnectAttempts = 0;
    YTMUPushPresence();
}

- (void)startHeartbeat:(NSTimeInterval)interval {
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_heartbeatTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
        (uint64_t)(interval * NSEC_PER_SEC), 1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{ [weakSelf heartbeatTick]; });
    dispatch_resume(_heartbeatTimer);
}

- (void)heartbeatTick {
    // No ACK since the last beat -> zombie connection. Kill and resume.
    if (_awaitingAck) {
        NSLog(@"[YTMU] heartbeat ACK missed, reconnecting");
        [self teardownKeepingSession:YES];
        [self scheduleReconnectAfter:0.5];
        return;
    }
    _awaitingAck = YES;
    [self sendHeartbeatRaw];
}

- (void)sendHeartbeatRaw {
    [self send:@{ @"op": @(1), @"d": _sequence ? @(_sequence) : [NSNull null] }];
}

- (void)identify {
    [self send:@{
        @"op": @(2),
        @"d": @{
            @"token": kDiscordToken,
            @"properties": @{ @"os": @"iOS", @"browser": @"YTMU", @"device": @"YTMU" },
            @"presence": @{ @"status": @"online", @"afk": @NO }
        }
    }];
}

- (void)sendResume {
    [self send:@{
        @"op": @(6),
        @"d": @{
            @"token": kDiscordToken,
            @"session_id": _sessionID ?: @"",
            @"seq": @(_sequence)
        }
    }];
}

- (void)sendActivityTitle:(NSString *)title
                   artist:(NSString *)artist
                    album:(NSString *)album
                 imageKey:(NSString *)imageKey
              durationSec:(double)durationSec
               startEpoch:(NSTimeInterval)startEpoch {
    if (!_identified) { [self connect]; return; } // READY/RESUMED re-pushes for us

    NSTimeInterval end = startEpoch + durationSec;
    NSMutableDictionary *activity = [@{
        @"name": @"YouTube Music",
        @"type": @(2),
        @"details": title ?: @"",
        @"state": artist ?: @"",
        @"application_id": kDiscordAppID,
        @"timestamps": @{
            @"start": @((long long)(startEpoch * 1000)),
            @"end": @((long long)(end * 1000))
        }
    } mutableCopy];

    if (imageKey.length > 0) {
        NSMutableDictionary *assets = [@{ @"large_image": imageKey } mutableCopy];
        // Only add hover text if it's meaningfully different from what's already visible.
        if (album.length && ![album isEqualToString:artist] && ![album isEqualToString:title]) {
            assets[@"large_text"] = album;
        }
        activity[@"assets"] = assets;
    }

    [self send:@{
        @"op": @(3),
        @"d": @{ @"since": @(0), @"activities": @[ activity ], @"status": @"online", @"afk": @NO }
    }];
}

- (void)clearPresence {
    if (!_identified) return;
    [self send:@{
        @"op": @(3),
        @"d": @{ @"since": @(0), @"activities": @[], @"status": @"online", @"afk": @NO }
    }];
}

- (void)send:(NSDictionary *)payload {
    if (!_socket) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!str) return;
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:str];
    __weak typeof(self) weakSelf = self;
    [_socket sendMessage:msg completionHandler:^(NSError *error) {
        if (!error) return;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSLog(@"[YTMU] gateway send error: %@", error.localizedDescription);
        [self teardownKeepingSession:YES];
        [self scheduleReconnectWithBackoff];
    }];
}

- (void)teardownKeepingSession:(BOOL)keep {
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    [_socket cancel];
    _socket = nil;
    [_session invalidateAndCancel];
    _session = nil;
    _identified = NO;
    _connecting = NO;
    _awaitingAck = NO;
    if (!keep) {
        _sessionID = nil;
        _resumeURL = nil;
    }
}

// Exponential backoff: 1s, 2s, 4s ... capped at 30s. Reset on READY/RESUMED.
- (void)scheduleReconnectWithBackoff {
    NSTimeInterval delay = MIN(pow(2.0, (double)_reconnectAttempts), 30.0);
    _reconnectAttempts++;
    [self scheduleReconnectAfter:delay];
}

- (void)scheduleReconnectAfter:(NSTimeInterval)delay {
    if (_reconnectScheduled) return;
    _reconnectScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_reconnectScheduled = NO;
        // Only chase the connection while something is actually playing;
        // otherwise reconnect lazily on the next presence push.
        if (gPresenceActive) [self connect];
    });
}

@end

#pragma mark - Presence push (reads shared state)

static void YTMUPushPresence(void) {
    if (!gPresenceActive) return;
    [[YTMUDiscordGateway shared] sendActivityTitle:gTrackTitle
                                            artist:gTrackArtist
                                             album:gTrackAlbum
                                          imageKey:gTrackImageKey
                                       durationSec:gTrackDuration
                                        startEpoch:gTrackStartEpoch];
}

#pragma mark - Artwork upload + external asset registration

static void YTMURegisterExternalAsset(NSString *imageURL, void (^completion)(NSString *assetKey));

// Per-track filename derived from trackKey -> no overwrite race between
// an in-flight registration for track A and a fresh upload for track B.
static void YTMUResolveArtwork(UIImage *artwork, NSString *trackKey, void (^completion)(NSString *assetKey)) {
    NSData *jpeg = UIImageJPEGRepresentation(artwork, 0.8);
    if (!jpeg) { completion(nil); return; }

    NSString *filename = [NSString stringWithFormat:@"%@.jpg", YTMUHashKey(trackKey)];
    NSString *putURLString = [kNextcloudWebDAVURL stringByAppendingString:filename]; // folder URL ends with /

    NSMutableURLRequest *putReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:putURLString]];
    putReq.HTTPMethod = @"PUT";
    NSString *authString = [NSString stringWithFormat:@"%@:%@", kNextcloudUser, kNextcloudPass];
    NSString *authBase64 = [[authString dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    [putReq setValue:[NSString stringWithFormat:@"Basic %@", authBase64] forHTTPHeaderField:@"Authorization"];
    putReq.HTTPBody = jpeg;

    NSURLSessionDataTask *uploadTask = [[NSURLSession sharedSession] dataTaskWithRequest:putReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            NSLog(@"[YTMU] WebDAV PUT %@ status=%ld", filename, (long)status);
            if (error || status >= 400) { completion(nil); return; }
            // Public folder-share download URL for this single file
            NSString *publicURL = [NSString stringWithFormat:@"%@/download?path=%%2F&files=%@", kNextcloudPublicURL, filename];
            YTMURegisterExternalAsset(publicURL, completion);
        }];
    [uploadTask resume];
}

static void YTMURegisterExternalAsset(NSString *imageURL, void (^completion)(NSString *assetKey)) {
    NSString *endpoint = [NSString stringWithFormat:@"https://discord.com/api/v10/applications/%@/external-assets", kDiscordAppID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:kDiscordToken forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"urls": @[ imageURL ] } options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (error || !data || status >= 400) {
                NSLog(@"[YTMU] external-assets failed status=%ld", (long)status);
                completion(nil);
                return;
            }
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) { completion(nil); return; }
            NSString *path = [arr.firstObject objectForKey:@"external_asset_path"];
            NSLog(@"[YTMU] external asset resolved");
            completion(path ? [@"mp:" stringByAppendingString:path] : nil);
        }];
    [task resume];
}

// Debounced artwork resolution: only fires after the user stops skipping for ~800ms,
// so flying through tracks doesn't flood Nextcloud + Discord's external-assets endpoint.
static void YTMUScheduleArtwork(UIImage *artwork, NSString *trackKey) {
    if (!artwork) return;
    gPendingArtwork = artwork;
    NSInteger myToken = ++gArtToken;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Bail if another skip happened since, or we've moved off this track
        if (myToken != gArtToken) return;
        if (![gLastTrackKey isEqualToString:trackKey]) return;

        UIImage *img = gPendingArtwork;
        if (!img) return;

        YTMUResolveArtwork(img, trackKey, ^(NSString *assetKey) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!assetKey) return;
                YTMUStoreAssetKey(trackKey, assetKey); // cache even if we've moved on — replays get instant art
                // Only apply if this is still both the newest request AND the current track
                if (myToken == gArtToken && [gLastTrackKey isEqualToString:trackKey]) {
                    gTrackImageKey = assetKey;
                    YTMUPushPresence();
                }
            });
        });
    });
}

#pragma mark - Hook

@interface MPNowPlayingInfoCenter (YTMU)
- (void)ytmu_handleNowPlayingInfo:(NSDictionary *)info;
- (void)ytmu_scheduleClear;
@end

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    [self ytmu_handleNowPlayingInfo:info];
}

%new
- (void)ytmu_handleNowPlayingInfo:(NSDictionary *)info {
    BOOL playing = NO;
    NSString *title = @"", *artist = @"", *album = @"";
    double duration = 0, elapsed = 0;
    UIImage *artworkImage = nil;

    if (info) {
        NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate] ?: @(0);
        playing = [rate floatValue] > 0;
        title  = info[MPMediaItemPropertyTitle] ?: @"";
        artist = info[MPMediaItemPropertyArtist] ?: @"";
        album  = info[MPMediaItemPropertyAlbumTitle] ?: @"";
        duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
        elapsed  = [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
        MPMediaItemArtwork *artworkObj = info[MPMediaItemPropertyArtwork];
        artworkImage = artworkObj ? [artworkObj imageWithSize:CGSizeMake(512, 512)] : nil;
    }

    if (!info || !playing) {
        [self ytmu_scheduleClear];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        gClearToken++; // cancel any pending debounced clear

        NSString *trackKey = [NSString stringWithFormat:@"%@|%@", title, artist];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        if (![trackKey isEqualToString:gLastTrackKey]) {
            gLastTrackKey = trackKey;
            gTrackTitle = title;
            gTrackArtist = artist;
            gTrackAlbum = album;
            gTrackDuration = duration;
            gTrackStartEpoch = now - elapsed;
            gPresenceActive = YES;

            // Cache hit -> art shows instantly with the very first push, no upload at all
            gTrackImageKey = YTMUCachedAssetKey(trackKey);

            NSLog(@"[YTMU] NEW TRACK: %@ — %@%@", title, artist,
                  gTrackImageKey ? @" (art cached)" : @"");
            YTMUPushPresence();                              // instant text+progress (+art on cache hit)
            if (!gTrackImageKey) {
                YTMUScheduleArtwork(artworkImage, trackKey); // debounced art only when needed
            }
        } else {
            if (!gTrackImageKey && artworkImage) {
                YTMUScheduleArtwork(artworkImage, trackKey);
            }
            NSTimeInterval expected = now - gTrackStartEpoch;
            if (fabs(elapsed - expected) > 6.0) {
                // Throttle: buffering at track start can fire this several times in a burst
                if (now - gLastScrubPush > 2.0) {
                    NSLog(@"[YTMU] scrub/buffer resync");
                    gLastScrubPush = now;
                    gTrackStartEpoch = now - elapsed;
                    YTMUPushPresence();
                } else {
                    gTrackStartEpoch = now - elapsed; // resync silently, no extra push
                }
            }
        }
    });
}

%new
- (void)ytmu_scheduleClear {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger myToken = ++gClearToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (myToken == gClearToken) {
                NSLog(@"[YTMU] clearing presence");
                gPresenceActive = NO;
                gLastTrackKey = nil;
                gTrackImageKey = nil;
                gPendingArtwork = nil;
                [[YTMUDiscordGateway shared] clearPresence];
            }
        });
    });
}

%end

#pragma mark - App lifecycle: clear presence on termination

static void YTMUClearOnExit(void) {
    gPresenceActive = NO;
    gLastTrackKey = nil;
    gTrackImageKey = nil;
    gPendingArtwork = nil;
    [[YTMUDiscordGateway shared] clearPresence];
}

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        NSLog(@"[YTMU] termination notification, clearing presence");
        YTMUClearOnExit();
    }];
}
