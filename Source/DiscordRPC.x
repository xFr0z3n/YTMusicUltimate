#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

// Placeholders — substituted by GitHub Actions at build time, never commit real values
static NSString * const kDiscordToken       = @"__DISCORD_TOKEN__";
static NSString * const kDiscordAppID       = @"__DISCORD_APP_ID__";
static NSString * const kNextcloudWebDAVURL = @"__NEXTCLOUD_WEBDAV_URL__";
static NSString * const kNextcloudUser      = @"__NEXTCLOUD_USER__";
static NSString * const kNextcloudPass      = @"__NEXTCLOUD_PASS__";
static NSString * const kNextcloudPublicURL = @"__NEXTCLOUD_PUBLIC_URL__";

#pragma mark - Gateway client

@interface YTMUDiscordGateway : NSObject <NSURLSessionWebSocketDelegate>
+ (instancetype)shared;
- (void)connect;
- (void)updatePresenceWithTitle:(NSString *)title
                         artist:(NSString *)artist
                          album:(NSString *)album
                       imageKey:(NSString *)imageKey
                    durationSec:(double)durationSec
                     elapsedSec:(double)elapsedSec;
- (void)clearPresence;
@end

@implementation YTMUDiscordGateway {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_socket;
    dispatch_source_t _heartbeatTimer;
    NSInteger _sequence;
    BOOL _identified;
    BOOL _connecting;
}

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
    _sequence = 0;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    NSURL *url = [NSURL URLWithString:@"wss://gateway.discord.gg/?v=10&encoding=json"];
    _socket = [_session webSocketTaskWithURL:url];
    [_socket resume];
    [self receiveLoop];
}

- (void)receiveLoop {
    __weak typeof(self) weakSelf = self;
    [_socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) { [self teardown]; return; }
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
            NSDictionary *d = payload[@"d"];
            NSTimeInterval interval = [d[@"heartbeat_interval"] doubleValue] / 1000.0;
            [self startHeartbeat:interval];
            [self identify];
            break;
        }
        case 0: {
            if ([payload[@"t"] isEqualToString:@"READY"]) {
                _identified = YES;
                _connecting = NO;
            }
            break;
        }
        case 9:
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

- (void)updatePresenceWithTitle:(NSString *)title
                         artist:(NSString *)artist
                          album:(NSString *)album
                       imageKey:(NSString *)imageKey
                    durationSec:(double)durationSec
                     elapsedSec:(double)elapsedSec {
    if (!_identified) { [self connect]; return; }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval start = now - elapsedSec;
    NSTimeInterval end = start + durationSec;

    NSMutableDictionary *activity = [@{
        @"name": @"YouTube Music",
        @"type": @(2),
        @"details": title ?: @"",
        @"state": artist ?: @"",
        @"application_id": kDiscordAppID,
        @"timestamps": @{
            @"start": @((long long)(start * 1000)),
            @"end": @((long long)(end * 1000))
        }
    } mutableCopy];

    if (imageKey.length > 0) {
        activity[@"assets"] = @{ @"large_image": imageKey, @"large_text": album ?: @"" };
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
    [_socket sendMessage:msg completionHandler:^(NSError *error) {}];
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

#pragma mark - Artwork upload + external asset registration

static void YTMURegisterExternalAsset(NSString *imageURL, void (^completion)(NSString *assetKey));

static void YTMUUploadArtworkAndUpdatePresence(UIImage *artwork, NSString *title, NSString *artist,
                                                NSString *album, double durationSec, double elapsedSec) {
    NSData *jpeg = UIImageJPEGRepresentation(artwork, 0.8);
    NSString *cacheBuster = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];

    NSMutableURLRequest *putReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kNextcloudWebDAVURL]];
    putReq.HTTPMethod = @"PUT";
    NSString *authString = [NSString stringWithFormat:@"%@:%@", kNextcloudUser, kNextcloudPass];
    NSString *authBase64 = [[authString dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    [putReq setValue:[NSString stringWithFormat:@"Basic %@", authBase64] forHTTPHeaderField:@"Authorization"];
    putReq.HTTPBody = jpeg;

    NSURLSessionDataTask *uploadTask = [[NSURLSession sharedSession] dataTaskWithRequest:putReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) return;
            NSString *publicURL = [NSString stringWithFormat:@"%@?t=%@", kNextcloudPublicURL, cacheBuster];
            YTMURegisterExternalAsset(publicURL, ^(NSString *assetKey) {
                [[YTMUDiscordGateway shared] updatePresenceWithTitle:title
                                                                artist:artist
                                                                 album:album
                                                              imageKey:assetKey
                                                           durationSec:durationSec
                                                            elapsedSec:elapsedSec];
            });
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
            if (error || !data) { completion(nil); return; }
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) { completion(nil); return; }
            NSString *path = [arr.firstObject objectForKey:@"external_asset_path"];
            completion(path ? [@"mp:" stringByAppendingString:path] : nil);
        }];
    [task resume];
}

#pragma mark - Hook

@interface MPNowPlayingInfoCenter (YTMU)
- (void)ytmu_handleNowPlayingInfo:(NSDictionary *)info;
@end

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;
    [self ytmu_handleNowPlayingInfo:info];
}

%new
- (void)ytmu_handleNowPlayingInfo:(NSDictionary *)info {
    if (!info) { [[YTMUDiscordGateway shared] clearPresence]; return; }

    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate] ?: @(0);
    if ([rate floatValue] <= 0) { [[YTMUDiscordGateway shared] clearPresence]; return; }

    NSString *title  = info[MPMediaItemPropertyTitle] ?: @"";
    NSString *artist = info[MPMediaItemPropertyArtist] ?: @"";
    NSString *album  = info[MPMediaItemPropertyAlbumTitle] ?: @"";
    double duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
    double elapsed  = [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];

    MPMediaItemArtwork *artworkObj = info[MPMediaItemPropertyArtwork];
    UIImage *artworkImage = artworkObj ? [artworkObj imageWithSize:CGSizeMake(512, 512)] : nil;

    if (artworkImage) {
        YTMUUploadArtworkAndUpdatePresence(artworkImage, title, artist, album, duration, elapsed);
    } else {
        [[YTMUDiscordGateway shared] updatePresenceWithTitle:title artist:artist album:album
                                                      imageKey:nil durationSec:duration elapsedSec:elapsed];
    }
}

%end
