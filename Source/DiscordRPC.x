#import <MediaPlayer/MediaPlayer.h>

// EDIT THIS before building — your RPi5's LAN IP or hostname
static NSString * const kRPiEndpoint = @"http://192.168.1.XXX:5005/nowplaying";

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;

    if (!info) {
        // Nothing playing / stopped
        [self ytmu_postPlaybackState:nil];
        return;
    }

    NSString *title  = info[MPMediaItemPropertyTitle] ?: @"";
    NSString *artist = info[MPMediaItemPropertyArtist] ?: @"";
    NSString *album  = info[MPMediaItemPropertyAlbumTitle] ?: @"";
    NSNumber *duration = info[MPMediaItemPropertyPlaybackDuration] ?: @(0);
    NSNumber *elapsed  = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?: @(0);
    NSNumber *rate     = info[MPNowPlayingInfoPropertyPlaybackRate] ?: @(0);

    NSDictionary *payload = @{
        @"title": title,
        @"artist": artist,
        @"album": album,
        @"duration": duration,
        @"elapsed": elapsed,
        @"playing": @([rate floatValue] > 0)
    };

    [self ytmu_postPlaybackState:payload];
}

%new
- (void)ytmu_postPlaybackState:(NSDictionary *)payload {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kRPiEndpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSData *body = payload
        ? [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil]
        : [@"{\"stopped\":true}" dataUsingEncoding:NSUTF8StringEncoding];
    req.HTTPBody = body;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            // fire-and-forget; ignore errors so playback is never blocked
        }];
    [task resume];
}

%end
