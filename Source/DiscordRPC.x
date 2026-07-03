#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

// Placeholders — substituted by GitHub Actions at build time, never commit real values
static NSString * const kDiscordToken       = @"__DISCORD_TOKEN__";
static NSString * const kDiscordAppID       = @"__DISCORD_APP_ID__";
static NSString * const kNextcloudWebDAVURL = @"__NEXTCLOUD_WEBDAV_URL__";
static NSString * const kNextcloudUser      = @"__NEXTCLOUD_USER__";
static NSString * const kNextcloudPass      = @"__NEXTCLOUD_PASS__";
static NSString * const kNextcloudPublicURL = @"__NEXTCLOUD_PUBLIC_URL__";

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

static void YTMUPushPresence(void);

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
    NSLog(@"[YTMU] gateway connecting");
    _connecting = YES;
    _identified = NO;
    _sequence = 0;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    NSURL *url = [NSURL URLWithString:@"wss://gateway.discord.gg/?v=10&encoding=json"];
    _socket = [_session webSocketTaskWithURL:url];
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
            NSLog(@"[YTMU] gateway receive error: %@", error);
            [self teardown];
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
        case 10: {
            NSLog(@"[YTMU] gateway HELLO");
            NSDictionary *d = payload[@"d"];
            NSTimeInterval interval = [d[@"heartbeat_interval"] doubleValue] / 1000.0;
            [self startHeartbeat:interval];
            [self identify];
            break;
        }
        case 0: {
            if ([payload[@"t"] isEqualToString:@"READY"]) {
                NSLog(@"[YTMU] gateway READY");
                _identified = YES;
                _connecting = NO;
                dispatch_async(dispatch_get_main_queue(), ^{ YTMUPushPresence(); });
            }
            break;
        }
        case 1:
            [self sendHeartbeat];
            break;
        case 7:
            NSLog(@"[YTMU] gateway RECONNECT requested");
            [self teardown];
            break;
        case 9:
            NSLog(@"[YTMU] gateway INVALID SESSION");
            [self teardown];
            break;
        default:
            break;
    }
}

- (void)startHeartbeat:(NSTimeInterval)interval {
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_heartbeatTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
        (uint64_t)(interval * NSEC_PER_SEC), 1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{ [weakSelf sendHeartbeat]; });
    dispatch_resume(_heartbeatTimer);
}

- (void)sendHeartbeat {
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

- (void)sendActivityTitle:(NSString *)title
                   artist:(NSString *)artist
                    album:(NSString *)album
                 imageKey:(NSString *)imageKey
              durationSec:(double)durationSec
               startEpoch:(NSTimeInterval)startEpoch {
    if (!_identified) { [self connect]; return; }

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
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:str];
    [_socket sendMessage:msg completionHandler:^(NSError *error) {
        if (error) NSLog(@"[YTMU] gateway send error: %@", error);
    }];
}

- (void)teardown {
    if (_heartbeatTimer) { dispatch_source_cancel(_heartbeatTimer); _heartbeatTimer = nil; }
    [_socket cancel];
    _socket = nil;
    _session = nil;
    _identified = NO;
    _connecting = NO;
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

static void YTMUResolveArtwork(UIImage *artwork, void (^completion)(NSString *assetKey)) {
    NSData *jpeg = UIImageJPEGRepresentation(artwork, 0.8);
    if (!jpeg) { completion(nil); return; }
    NSString *cacheBuster = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];

    NSMutableURLRequest *putReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kNextcloudWebDAVURL]];
    putReq.HTTPMethod = @"PUT";
    NSString *authString = [NSString stringWithFormat:@"%@:%@", kNextcloudUser, kNextcloudPass];
    NSString *authBase64 = [[authString dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    [putReq setValue:[NSString stringWithFormat:@"Basic %@", authBase64] forHTTPHeaderField:@"Authorization"];
    putReq.HTTPBody = jpeg;

    NSURLSessionDataTask *uploadTask = [[NSURLSession sharedSession] dataTaskWithRequest:putReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            NSLog(@"[YTMU] WebDAV PUT status=%ld", (long)status);
            if (error || status >= 400) { completion(nil); return; }
            NSString *publicURL = [NSString stringWithFormat:@"%@?t=%@", kNextcloudPublicURL, cacheBuster];
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

        YTMUResolveArtwork(img, ^(NSString *assetKey) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Only apply if this is still both the newest request AND the current track
                if (myToken == gArtToken && assetKey && [gLastTrackKey isEqualToString:trackKey]) {
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
            gTrackImageKey = nil;
            gPresenceActive = YES;

            NSLog(@"[YTMU] NEW TRACK: %@ — %@", title, artist);
            YTMUPushPresence();                        // instant text+progress
            YTMUScheduleArtwork(artworkImage, trackKey); // debounced art
        } else {
            if (!gTrackImageKey && artworkImage) {
                YTMUScheduleArtwork(artworkImage, trackKey);
            }
            NSTimeInterval expected = now - gTrackStartEpoch;
            if (fabs(elapsed - expected) > 6.0) {  // wider threshold — avoids jitter spam
                NSLog(@"[YTMU] scrub detected");
                gTrackStartEpoch = now - elapsed;
                YTMUPushPresence();
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
