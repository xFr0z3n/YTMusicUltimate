#import <MediaPlayer/MediaPlayer.h>

// Your Discord token
static NSString * const kDiscordToken = @"YOUR_USER_TOKEN_HERE";

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    %orig;

    if (!info) {
        [self ytmu_clearDiscordStatus];
        return;
    }

    NSString *title  = info[MPMediaItemPropertyTitle] ?: @"";
    NSString *artist = info[MPMediaItemPropertyArtist] ?: @"";
    NSNumber *rate    = info[MPNowPlayingInfoPropertyPlaybackRate] ?: @(0);

    if ([rate floatValue] > 0) {
        [self ytmu_updateDiscordStatus:title artist:artist];
    } else {
        [self ytmu_clearDiscordStatus];
    }
}

%new
- (void)ytmu_updateDiscordStatus:(NSString *)title artist:(NSString *)artist {
    NSString *text = [NSString stringWithFormat:@"🎵 %@ — %@", title, artist];
    [self ytmu_sendCustomStatus:text];
}

%new
- (void)ytmu_clearDiscordStatus {
    [self ytmu_sendCustomStatus:nil];
}

%new
- (void)ytmu_sendCustomStatus:(NSString *)text {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://discord.com/api/v10/users/@me/settings"]];
    req.HTTPMethod = @"PATCH";
    [req setValue:kDiscordToken forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *statusDict = text ? @{ @"text": text } : @{ @"text": @"" };
    NSDictionary *body = @{ @"custom_status": statusDict };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            
        }];
    [task resume];
}

%end
