#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static NSMutableDictionary *OVKUserAvatarURLs;
static NSMutableDictionary *OVKVideoDurations;
static BOOL OVKGroupsManagementMode = NO;
static BOOL OVKLoadingGlobalNews = NO;
static BOOL OVKSelectedGlobalNews = NO;
static BOOL OVKBuildingGroupsSelector = NO;
static id OVKNotificationPollerInstance;
static id OVKMessagePollerInstance;
static __weak id OVKSidebarControllerInstance;
static __weak id OVKFeedbackControllerInstance;
static __weak id OVKVisibleMessagesView;
static __weak id OVKVisibleChatController;
static BOOL OVKFeedbackSectionSelected = NO;
static NSUInteger OVKPendingNotificationCount = 0;
static NSUInteger OVKPendingMessageCount = 0;
static BOOL OVKMessagesNeedRefresh = NO;
static char OVKNewsInitializedKey;
static char OVKAvatarLoadingKey;
static NSString * const OVKGlobalNewsSelectionKey = @"OVKBridgeGlobalNewsSelected";

typedef struct {
    NSUInteger user;
    NSUInteger news;
    NSUInteger feedback;
    NSUInteger messages;
    NSUInteger friends;
    NSUInteger communities;
    NSUInteger photos;
    NSUInteger videos;
    NSUInteger music;
    NSUInteger favorites;
    NSUInteger settings;
    NSUInteger support;
    NSUInteger count;
} OVKSidebarSections;

static NSString *OVKBestVideoURL(id video)
{
    NSDictionary *files = nil;
    NSString *player = nil;
    @try {
        files = [video valueForKey:@"files"];
        player = [video valueForKey:@"player"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if ([files isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"mp4_1080", @"mp4_720", @"mp4_480", @"mp4_360", @"mp4_240", @"mp4_144"]) {
            NSString *url = [files objectForKey:key];
            if ([url isKindOfClass:[NSString class]] && url.length > 0) return url;
        }
    }
    return [player isKindOfClass:[NSString class]] ? player : nil;
}

static NSNumber *OVKWallOwnerID(id controller)
{
    id user = nil;
    id group = nil;
    @try {
        user = [controller valueForKey:@"ownerUser"];
        group = [controller valueForKey:@"ownerGroup"];
    } @catch (__unused NSException *exception) {}
    id entity = user ?: group;
    NSNumber *identifier = nil;
    @try { identifier = [entity valueForKey:@"id"] ?: [entity valueForKey:@"uid"]; }
    @catch (__unused NSException *exception) {}
    if (!identifier) return nil;
    return group ? @(-llabs(identifier.longLongValue)) : @(identifier.longLongValue);
}

static NSString *OVKWallAvatarURL(id controller)
{
    id entity = nil;
    @try { entity = [controller valueForKey:@"ownerUser"] ?: [controller valueForKey:@"ownerGroup"]; }
    @catch (__unused NSException *exception) {}
    for (NSString *key in @[@"photo_max_orig", @"photo_200", @"photo_big", @"photo_100", @"photo_50"]) {
        @try {
            NSString *url = [entity valueForKey:key];
            if ([url isKindOfClass:[NSString class]] && url.length > 0) return url;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

@interface NSObject (OVKLegacyVideoView)
- (void)setVideoDuration:(NSInteger)duration;
@end

@interface NSObject (OVKLegacyNewsfeedInfo)
- (id)initWithName:(NSString *)name andSourceId:(NSString *)sourceId;
- (void)setCurrentFeedTitle;
- (void)update;
- (id)initWithOwnerId:(NSNumber *)ownerID andAlbumId:(NSNumber *)albumID isAdmin:(BOOL)isAdmin;
- (id)initWithDictionary:(NSDictionary *)dictionary;
- (id)initWithAttachments:(NSArray *)attachments withIndex:(int)index withTotalCount:(int)total
                 withAlbum:(id)album withUid:(NSNumber *)uid;
- (void)showSelfInWindow;
@end

static NSString *OVKPercentEncode(NSString *value);

@interface OVKAvatarViewerController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, copy) NSString *imageURL;
@property (nonatomic, strong) NSNumber *ownerID;
@property (nonatomic, strong) NSMutableArray *imageURLs;
@property (nonatomic, strong) NSMutableSet *loadedPages;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIPageControl *pageControl;
- (instancetype)initWithImageURL:(NSString *)imageURL ownerID:(NSNumber *)ownerID;
@end

@implementation OVKAvatarViewerController

- (instancetype)initWithImageURL:(NSString *)imageURL ownerID:(NSNumber *)ownerID
{
    if ((self = [super init])) {
        self.imageURL = imageURL;
        self.ownerID = ownerID;
        self.imageURLs = [NSMutableArray array];
        if (imageURL.length > 0) [self.imageURLs addObject:imageURL];
        self.loadedPages = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.pagingEnabled = YES;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.delegate = self;
    [self.view addSubview:self.scrollView];

    self.pageControl = [[UIPageControl alloc] initWithFrame:CGRectMake(100.0, self.view.bounds.size.height - 52.0,
                                                                       self.view.bounds.size.width - 200.0, 32.0)];
    self.pageControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:self.pageControl];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(18.0, 24.0, 70.0, 44.0);
    close.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [close setTitle:@"Close" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
    [close addTarget:self action:@selector(ovk_close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    [self ovk_rebuildPages];
    [self ovk_fetchProfileAlbum];
}

- (void)ovk_rebuildPages
{
    for (UIView *view in [self.scrollView.subviews copy]) [view removeFromSuperview];
    [self.loadedPages removeAllObjects];
    CGSize pageSize = self.scrollView.bounds.size;
    for (NSUInteger index = 0; index < self.imageURLs.count; index++) {
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(pageSize.width * index, 0.0,
                                                                               pageSize.width, pageSize.height)];
        imageView.tag = 1000 + index;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.scrollView addSubview:imageView];
    }
    self.scrollView.contentSize = CGSizeMake(pageSize.width * self.imageURLs.count, pageSize.height);
    self.pageControl.numberOfPages = self.imageURLs.count;
    self.pageControl.currentPage = 0;
    self.pageControl.hidden = self.imageURLs.count < 2;
    [self ovk_loadPage:0];
    [self ovk_loadPage:1];
}

- (void)ovk_loadPage:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)self.imageURLs.count) return;
    NSNumber *page = @(index);
    if ([self.loadedPages containsObject:page]) return;
    [self.loadedPages addObject:page];
    NSString *urlString = [self.imageURLs objectAtIndex:index];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageView *imageView = (UIImageView *)[self.scrollView viewWithTag:1000 + index];
            if (image) imageView.image = image;
        });
    });
}

- (void)ovk_fetchProfileAlbum
{
    if (!self.ownerID) return;
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:@"access_token"] ?: @"";
    NSString *urlString = [NSString stringWithFormat:
        @"https://api.openvk.org/method/photos.get?owner_id=%@&album_id=-6&count=50&photo_sizes=1&access_token=%@",
        self.ownerID, OVKPercentEncode(token)];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
        if (data.length == 0) return;
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        NSDictionary *response = [root objectForKey:@"response"];
        NSArray *items = [response objectForKey:@"items"];
        if (![items isKindOfClass:[NSArray class]]) return;
        NSMutableArray *urls = [NSMutableArray array];
        if (self.imageURL.length > 0) [urls addObject:self.imageURL];
        for (NSDictionary *photo in items) {
            NSString *url = [photo objectForKey:@"photo_2560"] ?: [photo objectForKey:@"photo_1280"] ?:
                            [photo objectForKey:@"photo_807"] ?: [photo objectForKey:@"photo_604"];
            if (url.length > 0 && ![urls containsObject:url]) [urls addObject:url];
        }
        if (urls.count == 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.imageURLs = urls;
            [self ovk_rebuildPages];
        });
    });
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    NSInteger page = (NSInteger)llround(scrollView.contentOffset.x / MAX(scrollView.bounds.size.width, 1.0));
    self.pageControl.currentPage = page;
    [self ovk_loadPage:page - 1];
    [self ovk_loadPage:page];
    [self ovk_loadPage:page + 1];
}

- (void)ovk_close
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static NSString * const OVKBridgeNotificationArrived = @"OVKBridgeNotificationArrived";
static NSString * const OVKBridgeMessageArrived = @"OVKBridgeMessageArrived";
static BOOL OVKFeedbackNeedsRefresh = NO;
static void OVKLogRequest(NSString *event, NSString *value, NSInteger status);
static NSString *OVKPercentEncode(NSString *value);

static void OVKDumpMessagingRuntime(void)
{
    for (NSString *name in @[@"MessagesView", @"iPadChatViewController"]) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selector = NSStringFromSelector(method_getName(methods[i]));
            if ([selector rangeOfString:@"Message" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [selector rangeOfString:@"reload" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [selector rangeOfString:@"update" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                OVKLogRequest(@"MESSAGE_METHOD", [NSString stringWithFormat:@"%@ %@ %s", name, selector,
                    method_getTypeEncoding(methods[i])], -1);
            }
        }
        free(methods);
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            OVKLogRequest(@"MESSAGE_IVAR", [NSString stringWithFormat:@"%@ %s %s", name,
                ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i])], -1);
        }
        free(ivars);
    }
}

static void OVKUpdateFeedbackBadge(void)
{
    id sidebar = OVKSidebarControllerInstance;
    if (!sidebar) return;
    Ivar ivar = class_getInstanceVariable([sidebar class], "_sections");
    if (!ivar) ivar = class_getInstanceVariable([sidebar class], "sections");
    if (!ivar) return;
    OVKSidebarSections *sections = (OVKSidebarSections *)((uint8_t *)(__bridge void *)sidebar + ivar_getOffset(ivar));
    UITableView *table = nil;
    @try { table = [sidebar valueForKey:@"tableView"]; }
    @catch (__unused NSException *exception) {}
    if (![table isKindOfClass:[UITableView class]]) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)sections->feedback inSection:0];
    UITableViewCell *cell = [table cellForRowAtIndexPath:path];
    if (!cell) return;
    const NSInteger badgeTag = 0x4f564b46;
    UILabel *badge = (UILabel *)[cell.contentView viewWithTag:badgeTag];
    if (OVKPendingNotificationCount == 0) {
        [badge removeFromSuperview];
        return;
    }
    if (!badge) {
        badge = [[UILabel alloc] initWithFrame:CGRectMake(cell.contentView.bounds.size.width - 44.0, 11.0, 30.0, 20.0)];
        badge.tag = badgeTag;
        badge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        badge.backgroundColor = [UIColor colorWithRed:0.29 green:0.52 blue:0.76 alpha:1.0];
        badge.textColor = [UIColor whiteColor];
        badge.font = [UIFont boldSystemFontOfSize:12.0];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 9.0;
        badge.clipsToBounds = YES;
        [cell.contentView addSubview:badge];
    }
    badge.text = OVKPendingNotificationCount > 99 ? @"99+" :
        [NSString stringWithFormat:@"%lu", (unsigned long)OVKPendingNotificationCount];
    OVKLogRequest(@"NOTIF_BADGE", badge.text, -1);
}

static void OVKUpdateMessagesBadge(void)
{
    id sidebar = OVKSidebarControllerInstance;
    if (!sidebar) return;
    Ivar ivar = class_getInstanceVariable([sidebar class], "_sections");
    if (!ivar) ivar = class_getInstanceVariable([sidebar class], "sections");
    if (!ivar) return;
    OVKSidebarSections *sections = (OVKSidebarSections *)((uint8_t *)(__bridge void *)sidebar + ivar_getOffset(ivar));
    UITableView *table = nil;
    @try { table = [sidebar valueForKey:@"tableView"]; }
    @catch (__unused NSException *exception) {}
    UITableViewCell *cell = [table cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:(NSInteger)sections->messages inSection:0]];
    if (!cell) return;
    const NSInteger tag = 0x4f564b4d;
    UILabel *badge = (UILabel *)[cell.contentView viewWithTag:tag];
    if (OVKPendingMessageCount == 0) { [badge removeFromSuperview]; return; }
    if (!badge) {
        badge = [[UILabel alloc] initWithFrame:CGRectMake(cell.contentView.bounds.size.width - 44.0, 11.0, 30.0, 20.0)];
        badge.tag = tag;
        badge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        badge.backgroundColor = [UIColor colorWithRed:0.29 green:0.52 blue:0.76 alpha:1.0];
        badge.textColor = [UIColor whiteColor];
        badge.font = [UIFont boldSystemFontOfSize:12.0];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 9.0;
        badge.clipsToBounds = YES;
        [cell.contentView addSubview:badge];
    }
    badge.text = OVKPendingMessageCount > 99 ? @"99+" :
        [NSString stringWithFormat:@"%lu", (unsigned long)OVKPendingMessageCount];
}

@interface OVKNotificationPoller : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastSignature;
@property (nonatomic, copy) NSString *brokerCursor;
@property (nonatomic, assign) BOOL brokerCursorSynced;
@property (nonatomic, assign) BOOL polling;
- (void)start;
- (void)poll;
@end

@implementation OVKNotificationPoller

- (void)start
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationInactive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        [self applicationActive:nil];
    }
}

- (void)applicationActive:(NSNotification *)notification
{
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(poll)
                                                 userInfo:nil repeats:YES];
    [self poll];
}

- (void)applicationInactive:(NSNotification *)notification
{
    [self.timer invalidate];
    self.timer = nil;
}

- (void)poll
{
    if (self.polling) return;
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:@"access_token"];
    if (token.length == 0) return;
    self.polling = YES;
    NSString *cursor = self.brokerCursor.length > 0 ? self.brokerCursor : @"0";
    NSString *urlString = [NSString stringWithFormat:
        @"https://api.openvk.org/method/notifications.fetch?last_id=%@&access_token=%@",
        OVKPercentEncode(cursor), OVKPercentEncode(token)];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
        if (data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.polling = NO; });
            return;
        }
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *response = [root objectForKey:@"response"];
        NSArray *items = [response objectForKey:@"items"];
        NSString *newCursor = [response objectForKey:@"new_lastId"];
        if (![newCursor isKindOfClass:[NSString class]] || newCursor.length == 0) {
            newCursor = [response objectForKey:@"next_last_id"];
        }
        if (![items isKindOfClass:[NSArray class]]) items = @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.polling = NO;
            if ([newCursor isKindOfClass:[NSString class]] && newCursor.length > 0 &&
                ![newCursor isEqualToString:@"0"]) {
                self.brokerCursor = newCursor;
            }
            // The first fetch only synchronizes the Redis stream cursor. Showing
            // its backlog would replay up to an hour of old notifications.
            if (!self.brokerCursorSynced) {
                self.brokerCursorSynced = YES;
                OVKLogRequest(@"NOTIF_CURSOR", self.brokerCursor ?: @"0", (NSInteger)items.count);
                return;
            }
            if (items.count == 0) return;
            NSDictionary *item = [[items lastObject] isKindOfClass:[NSDictionary class]] ? [items lastObject] : nil;
            OVKLogRequest(@"NOTIF_FETCH", self.brokerCursor ?: @"0", (NSInteger)items.count);
            OVKFeedbackNeedsRefresh = YES;
            OVKPendingNotificationCount += items.count;
            OVKUpdateFeedbackBadge();
            [[NSNotificationCenter defaultCenter] postNotificationName:OVKBridgeNotificationArrived object:item];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"countersDidChanged" object:nil];
            [self showBannerForItem:item profiles:[response objectForKey:@"profiles"] groups:[response objectForKey:@"groups"]];
        });
    });
}

- (void)showBannerForItem:(NSDictionary *)item profiles:(NSArray *)profiles groups:(NSArray *)groups
{
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;
    UIView *old = [window viewWithTag:0x4f564b4e];
    [old removeFromSuperview];
    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(16.0, -72.0, window.bounds.size.width - 32.0, 60.0)];
    banner.tag = 0x4f564b4e;
    banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    banner.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
    banner.layer.cornerRadius = 9.0;
    NSDictionary *actor = [[profiles firstObject] isKindOfClass:[NSDictionary class]] ? [profiles firstObject] : nil;
    BOOL actorIsGroup = NO;
    if (!actor && [[groups firstObject] isKindOfClass:[NSDictionary class]]) {
        actor = [groups firstObject];
        actorIsGroup = YES;
    }
    NSString *name = actorIsGroup ? [actor objectForKey:@"name"] :
        [NSString stringWithFormat:@"%@ %@", [actor objectForKey:@"first_name"] ?: @"",
                                           [actor objectForKey:@"last_name"] ?: @""];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (name.length == 0) name = @"Someone";
    NSString *type = [item objectForKey:@"type"];
    NSDictionary *messages = @{
        @"like_post": @"liked your post",
        @"like_photo": @"liked your photo",
        @"comment_post": @"commented on your post",
        @"comment_photo": @"commented on your photo",
        @"copy_post": @"shared your post",
        @"wall": @"left a post on your wall",
        @"sent_gift": @"sent you a gift",
        @"friend_accepted": @"accepted your friend request"
    };
    NSString *action = [messages objectForKey:type] ?: @"sent you a notification";

    UIImageView *avatar = [[UIImageView alloc] initWithFrame:CGRectMake(8.0, 8.0, 44.0, 44.0)];
    avatar.layer.cornerRadius = 5.0;
    avatar.clipsToBounds = YES;
    avatar.contentMode = UIViewContentModeScaleAspectFill;
    [banner addSubview:avatar];
    NSString *avatarURL = [actor objectForKey:@"photo_100"] ?: [actor objectForKey:@"photo_medium_rec"] ?:
                          [actor objectForKey:@"photo"] ?: [actor objectForKey:@"photo_50"];
    if (avatarURL.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *avatarData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
            UIImage *image = avatarData.length > 0 ? [UIImage imageWithData:avatarData] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ if (banner.superview) avatar.image = image; });
        });
    }

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(62.0, 7.0, banner.bounds.size.width - 72.0, 46.0)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.textColor = [UIColor whiteColor];
    label.numberOfLines = 2;
    label.font = [UIFont boldSystemFontOfSize:15.0];
    label.text = [NSString stringWithFormat:@"%@\n%@", name, action];
    [banner addSubview:label];
    [window addSubview:banner];
    [UIView animateWithDuration:0.25 animations:^{
        banner.frame = CGRectMake(16.0, 24.0, window.bounds.size.width - 32.0, 60.0);
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.25 delay:4.0 options:0 animations:^{
            banner.frame = CGRectMake(16.0, -72.0, window.bounds.size.width - 32.0, 60.0);
        } completion:^(__unused BOOL done) { [banner removeFromSuperview]; }];
    }];
}

@end

@interface OVKMessagePoller : NSObject
@property (nonatomic, copy) NSString *server;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *ts;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, strong) NSMutableSet *seenMessageIDs;
- (void)start;
@end

@implementation OVKMessagePoller

- (void)start
{
    self.seenMessageIDs = [NSMutableSet set];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becameInactive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) [self becameActive:nil];
}

- (void)becameActive:(NSNotification *)note
{
    if (self.active) return;
    self.active = YES;
    self.generation++;
    [self connect:self.generation];
}

- (void)becameInactive:(NSNotification *)note
{
    self.active = NO;
    self.generation++;
}

- (void)connect:(NSUInteger)generation
{
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:@"access_token"];
    if (!self.active || token.length == 0) return;
    NSString *url = [NSString stringWithFormat:
        @"https://api.openvk.org/method/messages.getLongPollServer?need_pts=1&lp_version=2&access_token=%@",
        OVKPercentEncode(token)];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
        NSDictionary *root = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *response = [root objectForKey:@"response"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.active || generation != self.generation) return;
            self.server = [response objectForKey:@"server"];
            self.key = [response objectForKey:@"key"];
            self.ts = [[response objectForKey:@"ts"] description];
            if (self.server.length && self.key.length && self.ts.length) {
                OVKLogRequest(@"MESSAGE_LP_CONNECT", self.server, -1);
                [self poll:generation];
            } else {
                [self retryConnect:generation];
            }
        });
    });
}

- (void)retryConnect:(NSUInteger)generation
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.active && generation == self.generation) [self connect:generation];
    });
}

- (void)poll:(NSUInteger)generation
{
    if (!self.active || generation != self.generation) return;
    NSString *separator = [self.server rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
    NSString *url = [self.server stringByAppendingFormat:
        @"%@act=a_check&key=%@&ts=%@&wait=25&mode=2&version=2&ovk_bridge=1",
        separator, OVKPercentEncode(self.key), OVKPercentEncode(self.ts)];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
        NSDictionary *response = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.active || generation != self.generation) return;
            if ([[response objectForKey:@"failed"] integerValue] != 0 || ![response isKindOfClass:[NSDictionary class]]) {
                [self retryConnect:generation];
                return;
            }
            id newTS = [response objectForKey:@"ts"];
            if (newTS) self.ts = [newTS description];
            NSArray *updates = [response objectForKey:@"updates"];
            for (id raw in updates) {
                if (![raw isKindOfClass:[NSArray class]] || [raw count] == 0 || [[raw objectAtIndex:0] integerValue] != 4) continue;
                NSNumber *messageID = [raw count] > 1 ? [raw objectAtIndex:1] : nil;
                if (messageID && [self.seenMessageIDs containsObject:messageID]) continue;
                if (messageID) [self.seenMessageIDs addObject:messageID];
                OVKPendingMessageCount++;
                OVKMessagesNeedRefresh = YES;
                OVKUpdateMessagesBadge();
                OVKLogRequest(@"MESSAGE_LP_EVENT", [raw description], -1);
                [[NSNotificationCenter defaultCenter] postNotificationName:OVKBridgeMessageArrived object:raw];
                id chat = OVKVisibleChatController;
                NSNumber *peerID = [raw count] > 3 ? [raw objectAtIndex:3] : nil;
                NSNumber *currentPeer = nil;
                @try { currentPeer = [chat valueForKey:@"currentChatPeer"]; }
                @catch (__unused NSException *exception) {}
                if (chat && peerID && [currentPeer longLongValue] == [peerID longLongValue]) {
                    NSString *text = [raw count] > 5 && [[raw objectAtIndex:5] isKindOfClass:[NSString class]] ? [raw objectAtIndex:5] : @"";
                    NSNumber *date = [raw count] > 4 ? [raw objectAtIndex:4] : @0;
                    NSDictionary *dictionary = @{
                        @"id": messageID ?: @0, @"mid": messageID ?: @0,
                        @"user_id": peerID, @"uid": peerID, @"from_id": peerID,
                        @"date": date ?: @0, @"read_state": @0, @"out": @0,
                        @"title": @"", @"body": text, @"text": text,
                        @"attachments": @[], @"fwd_messages": @[],
                        @"important": @0, @"deleted": @0, @"random_id": @0,
                        @"emoji": @YES
                    };
                    Class messageClass = NSClassFromString(@"VKMessage");
                    id message = [messageClass alloc];
                    SEL initializer = NSSelectorFromString(@"initWithDictionary:");
                    if ([message respondsToSelector:initializer]) {
                        message = ((id (*)(id, SEL, id))objc_msgSend)(message, initializer, dictionary);
                    } else {
                        message = nil;
                    }
                    if (message) {
                        id interlocutor = nil;
                        @try { interlocutor = [chat valueForKey:@"currentInterlocutor"]; }
                        @catch (__unused NSException *exception) {}
                        if (!interlocutor) {
                            @try { interlocutor = [chat valueForKey:@"_currentInterlocutor"]; }
                            @catch (__unused NSException *exception) {}
                        }
                        if (interlocutor) {
                            @try { [message setValue:interlocutor forKey:@"user"]; }
                            @catch (__unused NSException *exception) {}
                        }
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"messageDidSended"
                                                                            object:message userInfo:nil];
                        OVKLogRequest(@"MESSAGE_LIVE_INSERT", [messageID description], -1);
                    }
                }
            }
            [self poll:generation];
        });
    });
}

@end

static NSString * const OVKInstanceKey = @"OVKBridgeInstanceHost";
static NSString * const OVKAccountsKey = @"OVKBridgeAccounts";

static NSString *OVKNormalizeInstance(NSString *value)
{
    NSString *candidate = [[value ?: @"" stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (candidate.length == 0) return @"api.openvk.org";
    // Never create NSURL here. NSURL itself is hooked by the bridge and asks
    // for the current instance, so doing that would recurse after a custom
    // instance has been saved and crash the app on every launch.
    NSRange scheme = [candidate rangeOfString:@"://"];
    if (scheme.location != NSNotFound) {
        candidate = [candidate substringFromIndex:NSMaxRange(scheme)];
    }
    NSRange terminator = [candidate rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
    if (terminator.location != NSNotFound) {
        candidate = [candidate substringToIndex:terminator.location];
    }
    NSRange credentials = [candidate rangeOfString:@"@" options:NSBackwardsSearch];
    if (credentials.location != NSNotFound) {
        candidate = [candidate substringFromIndex:NSMaxRange(credentials)];
    }
    while ([candidate hasSuffix:@"."]) {
        candidate = [candidate substringToIndex:candidate.length - 1];
    }
    return candidate.length > 0 ? candidate : @"api.openvk.org";
}

static NSString *OVKCurrentInstance(void)
{
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:OVKInstanceKey];
    return OVKNormalizeInstance(stored);
}

static NSArray *OVKAccounts(void)
{
    NSArray *accounts = [[NSUserDefaults standardUserDefaults] arrayForKey:OVKAccountsKey];
    return [accounts isKindOfClass:[NSArray class]] ? accounts : @[];
}

static void OVKStoreAccount(NSString *host, NSString *token, NSNumber *userID,
                            NSString *secret, NSString *label)
{
    if (token.length == 0 || userID == nil) return;
    host = OVKNormalizeInstance(host);
    NSMutableArray *accounts = [OVKAccounts() mutableCopy];
    NSUInteger existing = NSNotFound;
    for (NSUInteger i = 0; i < accounts.count; i++) {
        NSDictionary *account = accounts[i];
        if ([[account objectForKey:@"host"] isEqualToString:host] &&
            [[[account objectForKey:@"user_id"] stringValue] isEqualToString:[userID stringValue]]) {
            existing = i;
            break;
        }
    }
    NSMutableDictionary *account = [@{
        @"host": host,
        @"token": token,
        @"user_id": userID,
        @"label": label.length > 0 ? label : [NSString stringWithFormat:@"id%@", userID]
    } mutableCopy];
    if (secret.length > 0) [account setObject:secret forKey:@"secret"];
    if (existing == NSNotFound) [accounts addObject:account];
    else [accounts replaceObjectAtIndex:existing withObject:account];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:accounts forKey:OVKAccountsKey];
    [defaults synchronize];
}

static void OVKStoreCurrentAccount(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *token = [defaults stringForKey:@"access_token"];
    id rawUserID = [defaults objectForKey:@"user_id"];
    NSNumber *userID = [rawUserID respondsToSelector:@selector(longLongValue)]
        ? @([rawUserID longLongValue]) : nil;
    OVKStoreAccount(OVKCurrentInstance(), token, userID,
                    [defaults stringForKey:@"secret"], nil);
}

static void OVKRestartApplication(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}

static void OVKActivateAccount(NSDictionary *account)
{
    NSString *host = OVKNormalizeInstance([account objectForKey:@"host"]);
    NSString *token = [account objectForKey:@"token"];
    id userID = [account objectForKey:@"user_id"];
    if (token.length == 0 || userID == nil) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:host forKey:OVKInstanceKey];
    [defaults setObject:token forKey:@"access_token"];
    [defaults setObject:userID forKey:@"user_id"];
    NSString *secret = [account objectForKey:@"secret"];
    if (secret.length > 0) [defaults setObject:secret forKey:@"secret"];
    else [defaults removeObjectForKey:@"secret"];
    [defaults synchronize];
    OVKRestartApplication();
}

static void OVKBeginLoginOnInstance(NSString *instance)
{
    OVKStoreCurrentAccount();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:OVKNormalizeInstance(instance) forKey:OVKInstanceKey];
    for (NSString *key in @[@"access_token", @"user_id", @"secret"]) {
        [defaults removeObjectForKey:key];
    }
    [defaults synchronize];
    OVKRestartApplication();
}

static void OVKPresentAccounts(UIViewController *presenter)
{
    if (presenter == nil || presenter.presentedViewController != nil) return;
    OVKStoreCurrentAccount();
    NSString *title = [NSString stringWithFormat:@"OpenVK Accounts\n%@", OVKCurrentInstance()];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:title
        message:@"Switch an account or sign in on another OpenVK instance."
        preferredStyle:UIAlertControllerStyleAlert];
    for (NSDictionary *account in OVKAccounts()) {
        NSString *label = [account objectForKey:@"label"] ?: @"Account";
        NSString *host = [account objectForKey:@"host"] ?: @"";
        NSString *actionTitle = [NSString stringWithFormat:@"%@ — %@", label, host];
        [menu addAction:[UIAlertAction actionWithTitle:actionTitle
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                OVKActivateAccount(account);
            }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Add Account / Change Instance"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"OpenVK Instance"
                    message:@"Enter a domain, for example openvk.example"
                    preferredStyle:UIAlertControllerStyleAlert];
                [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
                    field.placeholder = @"instance.example";
                    field.text = OVKCurrentInstance();
                    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
                    field.autocorrectionType = UITextAutocorrectionTypeNo;
                    field.keyboardType = UIKeyboardTypeURL;
                }];
                [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [prompt addAction:[UIAlertAction actionWithTitle:@"Continue to Login"
                    style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *next) {
                        OVKBeginLoginOnInstance(prompt.textFields.firstObject.text);
                    }]];
                [presenter presentViewController:prompt animated:YES completion:nil];
            });
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:menu animated:YES completion:nil];
}

@interface NSObject (OVKLegacyImageLoading)
- (void)setImageWithPath:(id)path withFilter:(id)filter;
@end
#include <stdio.h>

static void OVKLogRequest(NSString *event, NSString *value, NSInteger status)
{
    if (value.length == 0) {
        return;
    }

    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"?#"];
    NSRange privatePart = [value rangeOfCharacterFromSet:separators];
    NSString *safeValue = privatePart.location == NSNotFound
        ? value
        : [value substringToIndex:privatePart.location];
    NSString *line = status >= 0
        ? [NSString stringWithFormat:@"%@ %ld %@\n", event, (long)status, safeValue]
        : [NSString stringWithFormat:@"%@ %@\n", event, safeValue];

    @synchronized([NSFileManager class]) {
        FILE *file = fopen("/tmp/OpenVKiPadBridge.log", "a");
        if (file != NULL) {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            fwrite(data.bytes, 1, data.length, file);
            fclose(file);
        }
    }
}

static void OVKUncaughtExceptionHandler(NSException *exception)
{
    OVKLogRequest(@"UNCAUGHT", [NSString stringWithFormat:@"%@: %@",
                  exception.name, exception.reason], -1);
    for (NSString *frame in exception.callStackSymbols) {
        OVKLogRequest(@"FRAME", frame, -1);
    }
}

static NSString *OVKProxyVideoURL(NSString *url)
{
    // Keep playback native: the legacy AVPlayer receives OpenVK's MP4 URL
    // directly, with no LAN transcoding/proxy dependency.
    return url;
}

static id OVKNormalizeJSON(id value)
{
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[value count]];
        for (id item in value) {
            [result addObject:OVKNormalizeJSON(item) ?: [NSNull null]];
        }
        return result;
    }

    if (![value isKindOfClass:[NSDictionary class]]) {
        return value;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (id key in value) {
        id normalized = OVKNormalizeJSON([value objectForKey:key]);
        if (normalized != nil) {
            [result setObject:normalized forKey:key];
        }
    }

    // OpenVK may expose unknown thumbnail dimensions as null. The legacy
    // client treats these fields as scalar numbers.
    if ([result objectForKey:@"url"] && [result objectForKey:@"type"]) {
        // VKPhotoSize in this client predates the modern API field name and
        // reads `src`, while OpenVK correctly returns the newer `url`.
        if (![result objectForKey:@"src"]) {
            [result setObject:[result objectForKey:@"url"] forKey:@"src"];
        }
        if ([[result objectForKey:@"width"] isKindOfClass:[NSNull class]]) {
            [result setObject:@0 forKey:@"width"];
        }
        if ([[result objectForKey:@"height"] isKindOfClass:[NSNull class]]) {
            [result setObject:@0 forKey:@"height"];
        }
    }

    for (NSString *arrayKey in @[@"attachments", @"copy_history"]) {
        id arrayValue = [result objectForKey:arrayKey];
        if (arrayValue != nil && ![arrayValue isKindOfClass:[NSArray class]]) {
            [result setObject:@[] forKey:arrayKey];
        }
    }

    // OpenVK's modern geo object is not compatible with VKGeo in the iPad
    // client and crashes layout calculation for otherwise valid wall posts.
    if ([result objectForKey:@"post_type"] && [result objectForKey:@"geo"]) {
        [result removeObjectForKey:@"geo"];
    }

    // Notification posts use the old `to_id` field where VKPost expects
    // owner_id in this client.
    if ([result objectForKey:@"to_id"] && [result objectForKey:@"id"] &&
        [result objectForKey:@"date"] && [result objectForKey:@"text"] &&
        ![result objectForKey:@"owner_id"]) {
        [result setObject:[result objectForKey:@"to_id"] forKey:@"owner_id"];
    }

    // VKNotification's legacy initializer treats these as optional objects,
    // but OpenVK serializes absent values as JSON null.
    if ([result objectForKey:@"type"] && [result objectForKey:@"date"] &&
        ([result objectForKey:@"parent"] || [result objectForKey:@"feedback"])) {
        for (NSString *key in @[@"parent", @"feedback", @"reply"]) {
            if ([[result objectForKey:key] isKindOfClass:[NSNull class]]) {
                [result removeObjectForKey:key];
            }
        }
    }

    // Keep the notification's proven-compatible id/from_id object, and copy
    // only avatar fields from the top-level profiles collection.
    NSArray *notificationProfiles = [result objectForKey:@"profiles"];
    NSArray *notificationItems = [result objectForKey:@"items"];
    if ([result objectForKey:@"last_viewed"] &&
        [notificationProfiles isKindOfClass:[NSArray class]] &&
        [notificationItems isKindOfClass:[NSArray class]]) {
        for (NSMutableDictionary *notification in notificationItems) {
            NSDictionary *feedback = [notification objectForKey:@"feedback"];
            if (![feedback isKindOfClass:[NSDictionary class]]) continue;
            NSArray *users = [feedback objectForKey:@"items"];
            if (![users isKindOfClass:[NSArray class]]) continue;
            for (NSMutableDictionary *user in users) {
                NSNumber *userID = [user objectForKey:@"from_id"] ?: [user objectForKey:@"id"];
                for (NSDictionary *profile in notificationProfiles) {
                    NSNumber *profileID = [profile objectForKey:@"id"] ?: [profile objectForKey:@"uid"];
                    if (![profileID isEqual:userID]) continue;
                    for (NSString *key in @[@"photo", @"photo_medium_rec", @"photo_50", @"photo_100", @"photo_200"]) {
                        id avatar = [profile objectForKey:key];
                        if (avatar && ![avatar isKindOfClass:[NSNull class]]) [user setObject:avatar forKey:key];
                    }
                    break;
                }
            }
        }
    }

    BOOL retina = YES;
    if ([result objectForKey:@"uid"] && ![result objectForKey:@"id"]) {
        [result setObject:[result objectForKey:@"uid"] forKey:@"id"];
    }
    if ([result objectForKey:@"photo"] && ![result objectForKey:@"photo_50"]) {
        [result setObject:[result objectForKey:@"photo"] forKey:@"photo_50"];
    }
    if ([result objectForKey:@"photo_medium_rec"] && ![result objectForKey:@"photo_100"]) {
        NSString *medium = [result objectForKey:@"photo_medium_rec"];
        // `normal.gif` is not generated for every legacy OpenVK avatar.
        // The API-provided tiny rendition is the reliable fallback here.
        NSString *large = medium;
        [result setObject:large forKey:@"photo_100"];
        [result setObject:large forKey:@"photo_200"];
    }
    if (([result objectForKey:@"first_name"] || [result objectForKey:@"name"]) && [result objectForKey:@"id"]) {
        NSString *bestAvatar = [result objectForKey:@"photo_200"] ?: [result objectForKey:@"photo_100"];
        if (retina && bestAvatar.length > 0) {
            for (NSString *key in @[@"photo_50", @"photo_100", @"photo_200", @"photo_max_orig"]) {
                [result setObject:bestAvatar forKey:key];
            }
        }
        if (bestAvatar.length > 0) {
            @synchronized (OVKUserAvatarURLs) {
                [OVKUserAvatarURLs setObject:bestAvatar
                                      forKey:[[result objectForKey:@"id"] stringValue]];
            }
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        id currentUserID = [defaults objectForKey:@"user_id"];
        if (currentUserID && [[currentUserID stringValue]
            isEqualToString:[[result objectForKey:@"id"] stringValue]]) {
            NSString *firstName = [result objectForKey:@"first_name"] ?: @"";
            NSString *lastName = [result objectForKey:@"last_name"] ?: @"";
            NSString *name = [[NSString stringWithFormat:@"%@ %@", firstName, lastName]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            OVKStoreAccount(OVKCurrentInstance(), [defaults stringForKey:@"access_token"],
                            @([currentUserID longLongValue]), [defaults stringForKey:@"secret"], name);
        }
        for (NSString *key in @[@"about", @"activities", @"interests", @"music", @"movies", @"tv", @"books", @"games", @"quotes", @"site", @"mobile_phone", @"home_phone", @"description", @"status", @"deactivated"]) {
            if ([[result objectForKey:key] isKindOfClass:[NSNull class]]) [result setObject:@"" forKey:key];
        }
    }

    NSArray *sizes = [result objectForKey:@"sizes"];
    if ([result objectForKey:@"album_id"] && [sizes isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *urls = [NSMutableDictionary dictionary];
        for (NSDictionary *size in sizes) {
            NSString *type = [size objectForKey:@"type"];
            NSString *url = [size objectForKey:@"url"] ?: [size objectForKey:@"src"];
            if (type.length > 0 && url.length > 0) {
                [urls setObject:url forKey:type];
            }
        }

        NSString *(^firstURL)(NSArray *) = ^NSString *(NSArray *types) {
            for (NSString *type in types) {
                NSString *url = [urls objectForKey:type];
                if (url.length > 0) return url;
            }
            return nil;
        };
        NSDictionary *legacy = @{
            @"photo_75": firstURL(@[@"s", @"m", @"x"]) ?: @"",
            @"photo_130": firstURL(@[@"m", @"s", @"x"]) ?: @"",
            @"photo_510": firstURL(@[@"x", @"r", @"q", @"m"]) ?: @"",
            @"photo_604": firstURL(@[@"x", @"r", @"q", @"m"]) ?: @"",
            @"photo_807": firstURL(@[@"y", @"x", @"r", @"m"]) ?: @"",
            @"photo_1280": firstURL(@[@"z", @"y", @"x", @"m"]) ?: @"",
            @"photo_2560": firstURL(@[@"w", @"z", @"y", @"x"]) ?: @""
        };
        [result addEntriesFromDictionary:legacy];
        // Prefer known-good CDN renditions. Some synthetic w/z URLs point to
        // thumbnail routes that do not exist for older uploads.
        NSString *maximum = firstURL(@[@"UPLOADED_MAXRES", @"w", @"z", @"y", @"x", @"q", @"m", @"r", @"s"]);
        if (retina && maximum.length > 0) {
            // Keep originals for full-screen fields, but avoid decoding them
            // for every tiny feed cell and exhausting the iOS 8 process RAM.
            NSString *small = firstURL(@[@"m", @"q", @"s", @"x"]) ?: maximum;
            NSString *medium = firstURL(@[@"x", @"y", @"q", @"m"]) ?: maximum;
            [result setObject:small forKey:@"photo_75"];
            [result setObject:small forKey:@"photo_130"];
            [result setObject:medium forKey:@"photo_510"];
            [result setObject:medium forKey:@"photo_604"];
            [result setObject:(firstURL(@[@"y", @"z", @"x"]) ?: maximum) forKey:@"photo_807"];
            [result setObject:maximum forKey:@"photo_1280"];
            [result setObject:maximum forKey:@"photo_2560"];
        }
        if ([[result objectForKey:@"text"] isKindOfClass:[NSNull class]]) {
            [result setObject:@"" forKey:@"text"];
        }
    }


    NSDictionary *albumSizes = [result objectForKey:@"sizes"];
    if ([result objectForKey:@"title"] && [result objectForKey:@"size"] && [albumSizes isKindOfClass:[NSDictionary class]]) {
        NSDictionary *maximum = [albumSizes objectForKey:@"UPLOADED_MAXRES"] ?: [albumSizes objectForKey:@"w"] ?: [albumSizes objectForKey:@"z"] ?: [albumSizes objectForKey:@"y"] ?: [albumSizes objectForKey:@"x"];
        NSString *cover = [maximum objectForKey:@"url"];
        if (cover.length > 0) [result setObject:cover forKey:@"thumb_src"];
        if ([[result objectForKey:@"description"] isKindOfClass:[NSNull class]]) [result setObject:@"" forKey:@"description"];

        NSArray *sizeValues = [albumSizes allValues];
        NSMutableDictionary *thumb = [NSMutableDictionary dictionaryWithDictionary:@{
            @"id": [result objectForKey:@"thumb_id"] ?: @0,
            @"album_id": [result objectForKey:@"id"] ?: @0,
            @"owner_id": [result objectForKey:@"owner_id"] ?: @0,
            @"text": @"",
            @"sizes": sizeValues
        }];
        [result setObject:OVKNormalizeJSON(thumb) forKey:@"thumb"];
        [result setObject:sizeValues forKey:@"sizes"];
        if (cover.length > 0) {
            [result setObject:cover forKey:@"photo_160"];
            [result setObject:cover forKey:@"photo_320"];
        }
    }

    NSArray *videoImages = [result objectForKey:@"image"];
    id rawVideoFiles = [result objectForKey:@"files"];
    if ([result objectForKey:@"id"] && ([result objectForKey:@"player"] || rawVideoFiles)) {
        NSDictionary *videoFiles = [rawVideoFiles isKindOfClass:[NSDictionary class]] ? rawVideoFiles : nil;
        OVKLogRequest(@"VIDEO_META", [NSString stringWithFormat:@"id=%@ duration=%@ files=%@ player=%@",
                      [result objectForKey:@"id"], [result objectForKey:@"duration"],
                      [videoFiles allKeys], [result objectForKey:@"player"]], -1);
        NSString *player = [result objectForKey:@"player"];
        if ([player isKindOfClass:[NSString class]]) {
            [result setObject:OVKProxyVideoURL(player) forKey:@"player"];
        }
        if (videoFiles) {
            NSMutableDictionary *proxiedFiles = [videoFiles mutableCopy];
            for (NSString *key in videoFiles) {
                NSString *fileURL = [videoFiles objectForKey:key];
                if ([fileURL isKindOfClass:[NSString class]]) {
                    [proxiedFiles setObject:OVKProxyVideoURL(fileURL) forKey:key];
                }
            }
            [result setObject:proxiedFiles forKey:@"files"];
        }
    }
    if ([result objectForKey:@"player"] && [videoImages isKindOfClass:[NSArray class]]) {
        NSString *bestImage = nil;
        NSInteger bestWidth = -1;
        for (NSDictionary *image in videoImages) {
            NSInteger width = [[image objectForKey:@"width"] integerValue];
            NSString *url = [image objectForKey:@"url"];
            if (url.length > 0 && width >= bestWidth) { bestWidth = width; bestImage = url; }
        }
        if (bestImage.length > 0) {
            for (NSString *key in @[@"photo_320", @"photo_640", @"photo_800", @"image_big"]) [result setObject:bestImage forKey:key];
        }
        if ([[result objectForKey:@"description"] isKindOfClass:[NSNull class]]) [result setObject:@"" forKey:@"description"];
        if ([[result objectForKey:@"duration"] isKindOfClass:[NSNull class]]) [result setObject:@0 forKey:@"duration"];
    }

    // Like/copy notifications carry a user (or users) in feedback. Comment
    // notifications carry a VK comment there and must stay unwrapped: treating
    // a comment as an array of users makes its text disappear in Feedback.
    if ([result objectForKey:@"type"] && [result objectForKey:@"date"] && [result objectForKey:@"parent"]) {
        NSString *notificationType = [result objectForKey:@"type"];
        id feedback = [result objectForKey:@"feedback"];
        BOOL feedbackContainsUsers = [notificationType hasPrefix:@"like_"] ||
                                     [notificationType hasPrefix:@"copy_"];
        if (feedbackContainsUsers && [feedback isKindOfClass:[NSDictionary class]] &&
            ![feedback objectForKey:@"items"]) {
            [result setObject:@{ @"count": @1, @"items": @[feedback] } forKey:@"feedback"];
        }
        if ([[result objectForKey:@"reply"] isKindOfClass:[NSNull class]]) [result removeObjectForKey:@"reply"];
        NSMutableDictionary *parent = [result objectForKey:@"parent"];
        if ([parent isKindOfClass:[NSMutableDictionary class]]) {
            for (NSString *key in @[@"copy_owner_id", @"copy_post_id"]) {
                if ([[parent objectForKey:key] isKindOfClass:[NSNull class]]) [parent setObject:@0 forKey:key];
            }
        }
    }

    // OpenVK exposes the modern messages schema while VK for iPad 2.0.4
    // instantiates its pre-5.x VKMessage model. Supply the harmless legacy
    // aliases/collections that the old decoder assumes are always present.
    if ([result objectForKey:@"date"] && [result objectForKey:@"out"] &&
        [result objectForKey:@"user_id"] &&
        ([result objectForKey:@"body"] || [result objectForKey:@"text"])) {
        id body = [result objectForKey:@"body"] ?: [result objectForKey:@"text"] ?: @"";
        if (![result objectForKey:@"body"]) [result setObject:body forKey:@"body"];
        if (![result objectForKey:@"text"]) [result setObject:body forKey:@"text"];
        if (![result objectForKey:@"uid"]) [result setObject:[result objectForKey:@"user_id"] forKey:@"uid"];
        if (![result objectForKey:@"from_id"]) [result setObject:[result objectForKey:@"user_id"] forKey:@"from_id"];
        if (![result objectForKey:@"read_state"]) [result setObject:@1 forKey:@"read_state"];
        if (![result objectForKey:@"title"]) [result setObject:@"" forKey:@"title"];
        if (![result objectForKey:@"deleted"]) [result setObject:@0 forKey:@"deleted"];
        if (![result objectForKey:@"important"]) [result setObject:@0 forKey:@"important"];
        if (![result objectForKey:@"random_id"]) [result setObject:@0 forKey:@"random_id"];
        if (![[result objectForKey:@"attachments"] isKindOfClass:[NSArray class]]) [result setObject:@[] forKey:@"attachments"];
        if (![[result objectForKey:@"fwd_messages"] isKindOfClass:[NSArray class]]) [result setObject:@[] forKey:@"fwd_messages"];
    }

    return result;
}

static NSString *OVKPercentEncode(NSString *value)
{
    CFStringRef encoded = CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault,
        (__bridge CFStringRef)value,
        NULL,
        CFSTR("!*'();:@&=+$,/?%#[]{}\" "),
        kCFStringEncodingUTF8
    );
    return CFBridgingRelease(encoded);
}

static NSString *OVKEmulateLegacyMethod(NSString *value)
{
    static NSDictionary *scripts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        scripts = @{
            @"execute.newsfeedGet":
                @"var feed=null; if(Args.ovk_global==1){feed=API.newsfeed.getGlobal({count:Args.count,start_from:Args.start_from,fields:'photo_50,photo_100,photo_200,verified'});} else {feed=API.newsfeed.get({count:Args.count,start_from:Args.start_from,fields:'photo_50,photo_100,photo_200,verified'});} var ids=[]; var i=0; while(i<feed.items.length){var post=feed.items[i]; if(post.copy_history && post.copy_history.length>0){var author=post.copy_history[0].from_id; if(author>0){ids.push(author);}} i=i+1;} if(ids.length>0){feed.profiles=feed.profiles+API.users.get({user_ids:ids,fields:'photo_50,photo_100,photo_200,verified'});} return feed;",
            @"execute.newsfeedGetRecommended":
                @"var feed=API.newsfeed.getGlobal({count:Args.count,start_from:Args.start_from,fields:'photo_50,photo_100,photo_200,verified'}); var ids=[]; var i=0; while(i<feed.items.length){var post=feed.items[i]; if(post.copy_history && post.copy_history.length>0){var author=post.copy_history[0].from_id; if(author>0){ids.push(author);}} i=i+1;} if(ids.length>0){feed.profiles=feed.profiles+API.users.get({user_ids:ids,fields:'photo_50,photo_100,photo_200,verified'});} return feed;",
            @"execute.newsfeedGetCount":
                @"return {next_from:'',post_ids:[]};",
            @"execute.loadUserSettings":
                @"return {ver:1,full:API.users.get({}),opt1:0,opt2:0,opt3:0,info:API.account.getInfo({})};",
            @"execute.loadUser5_0i":
                @"var full=API.users.get({user_ids:Args.user_id,fields:'photo_50,photo_100,photo_200,photo_max_orig,status,online,counters,city,country,sex,about,activities,interests,music,movies,tv,books,games,quotes,relation,relatives,education,universities,schools,career,occupation,personal,site,mobile_phone,home_phone,screen_name,followers_count,common_count,can_post,last_seen,friend_status,verified'}); var me=API.users.get({}); var own=full[0].id==me[0].id; var state=full[0].friend_status; if(!state){state=0;} full[0].can_write_private_message=1; full[0].can_send_friend_request=0; full[0].request_sent=0; if(own){full[0].can_write_private_message=0;} if(!own && state==0){full[0].can_send_friend_request=1;} if(state==1){full[0].request_sent=1;} full[0].friendState=state; if(own){full[0].can_post=1;} var friends=API.friends.get({user_id:Args.user_id,count:6,fields:'photo_50,photo_100,photo_200,online,verified'}); var albums=API.photos.getAlbums({owner_id:Args.user_id,count:6,need_covers:1,photo_sizes:1}); if(!albums){albums={count:0,items:[]}; full[0].counters.albums=0;} var videos=API.video.get({owner_id:Args.user_id,count:6,extended:1}); var pages=API.groups.get({user_id:Args.user_id,count:6,extended:1,fields:'photo_50,photo_100,photo_200,members_count,status,verified'}); var photos=API.photos.get({owner_id:Args.user_id,album_id:-6,count:50,extended:0}); if(!photos){photos={count:0,items:[]};} return {full:full[0],docs_count:0,relative_users:[],cities:[],profile_photos:photos,is_friend:{user_id:full[0].id,friend_status:state},saved_photos:0,tag_photos:0,wall_photos:0,friends:friends.items,mutual:[],pages:pages.items,albums:albums.items,videos:videos.items,countries:[],wall1:API.wall.get({owner_id:Args.user_id,count:10,extended:1,fields:'photo_50,photo_100,photo_200,verified'}),wall2:{count:0,items:[]}};",
            @"execute.loadGroup5_0i":
                @"var me=API.users.get({}); var groups=API.groups.getById({group_ids:Args.group_id,fields:'photo_50,photo_100,photo_200,members_count,status,description,site,city,country,can_post,can_see_all_posts,counters,verified'}); var owner=0-Args.group_id; var albums=API.photos.getAlbums({owner_id:owner,count:6,need_covers:1,photo_sizes:1}); var members=API.groups.getMembers({group_id:Args.group_id,count:6,fields:'photo_50,photo_100,photo_200,online,verified'}); var wall=API.wall.get({owner_id:owner,count:10,extended:1,fields:'photo_50,photo_100,photo_200,verified'}); var grpPhotos=API.photos.get({owner_id:owner,album_id:-6,count:50,extended:0}); if(!grpPhotos){grpPhotos={count:0,items:[]};} return {group:groups[0],albums:albums.items,main_album:null,videos:[],audios:[],photos:[],profile_photos:grpPhotos,topics:{count:0,items:[]},wall_photos:0,saved_photos:0,contacts:[],members:members.items,member:API.groups.isMember({group_id:Args.group_id,user_id:me[0].id,extended:1}),docs:0,wall1:wall,wall2:{count:0,items:[]}};",
            @"execute.loadGroup":
                @"var me=API.users.get({}); var groups=API.groups.getById({group_ids:Args.group_id,fields:'photo_50,photo_100,photo_200,members_count,status,description,site,city,country,can_post,can_see_all_posts,counters,verified'}); var owner=0-Args.group_id; var albums=API.photos.getAlbums({owner_id:owner,count:6,need_covers:1,photo_sizes:1}); var members=API.groups.getMembers({group_id:Args.group_id,count:6,fields:'photo_50,photo_100,photo_200,online,verified'}); var wall=API.wall.get({owner_id:owner,count:10,extended:1,fields:'photo_50,photo_100,photo_200,verified'}); var grpPhotos=API.photos.get({owner_id:owner,album_id:-6,count:50,extended:0}); if(!grpPhotos){grpPhotos={count:0,items:[]};} return {group:groups[0],albums:albums.items,main_album:null,videos:[],audios:[],photos:[],profile_photos:grpPhotos,topics:{count:0,items:[]},wall_photos:0,saved_photos:0,contacts:[],members:members.items,member:API.groups.isMember({group_id:Args.group_id,user_id:me[0].id,extended:1}),docs:0,wall1:wall,wall2:{count:0,items:[]}};",
            @"execute.getVideos":
                @"return {videos:API.video.get({owner_id:Args.owner_id,count:Args.count,offset:Args.offset}),albums:[]};",
            @"execute.loadMorePhotoAlbums":
                @"var target=Args.user_id; if(!target){target=Args.uid;} var albums=API.photos.getAlbums({owner_id:target,count:Args.count,offset:Args.offset,need_covers:1,photo_sizes:1}); if(!albums){albums={count:0,items:[]};} return {albums:albums,all_photos:{count:0,items:[]},tag_photos:[]};",
            @"execute.getDialogs":
                @"var conv=API.messages.getConversations({count:Args.count,offset:Args.offset,extended:1,fields:'photo_50,photo_100,photo_200,online,screen_name'}); var dialogs={count:conv.count,items:[]}; var i=0; while(i<conv.items.length){var row=conv.items[i]; var msg=row.last_message; if(msg){if(!msg.body){msg.body=msg.text;} if(!msg.text){msg.text=msg.body;} msg.uid=msg.user_id; msg.title=''; msg.deleted=0; msg.important=0; msg.random_id=0; msg.attachments=[]; msg.fwd_messages=[]; var unread=0; if(msg.out==0 && msg.read_state==0){unread=1;} dialogs.items.push({unread:unread,message:msg});} i=i+1;} return {chat_users:conv.profiles,users:conv.profiles,profiles:conv.profiles,dialogs:dialogs};",
            @"execute.getMessagesHistory":
                @"var target=Args.user_id; if(!target){target=Args.uid;} if(!target){target=Args.peer_id;} var start=Args.start_message_id; if(!start){start=Args.start_mid;} var history=API.messages.getHistory({user_id:target,count:Args.count,offset:Args.offset,start_message_id:start,rev:Args.rev,extended:1,fields:'photo_50,photo_100,photo_200,online,screen_name'}); return {messages:history,history:history,chat_users:history.profiles,users:history.profiles,profiles:history.profiles};",
            @"messages.getDialogs":
                @"var conv=API.messages.getConversations({count:Args.count,offset:Args.offset,extended:1,fields:'photo_50,photo_100,photo_200,online,screen_name'}); var dialogs={count:conv.count,items:[]}; var i=0; while(i<conv.items.length){var row=conv.items[i]; var msg=row.last_message; if(msg){if(!msg.body){msg.body=msg.text;} if(!msg.text){msg.text=msg.body;} msg.uid=msg.user_id; msg.title=''; msg.deleted=0; msg.important=0; msg.random_id=0; msg.attachments=[]; msg.fwd_messages=[]; var unread=0; if(msg.out==0 && msg.read_state==0){unread=1;} dialogs.items.push({unread:unread,message:msg});} i=i+1;} return dialogs;",
            @"messages.markAsRead":
                @"return 1;",
            @"messages.getLastActivity":
                @"return {online:0,time:0};",
            @"execute.loadGroupsSuggested":
                @"var groups=API.groups.get({count:5000,offset:0,extended:1,filter:Args.filter,fields:'photo_50,photo_100,photo_200,members_count,status,verified'}); return {groups:groups.items,suggested:[],invites:{count:0,items:[]},profiles:[],recommendations:{users:[],groups:[]}};",
            @"execute.getFriendRequests":
                @"var requests=API.friends.getRequests({count:Args.count,offset:Args.offset,extended:1,fields:'photo_50,photo_100,photo_200,online,friend_status'}); var i=0; while(i<requests.items.length){requests.items[i].user_id=requests.items[i].id; requests.items[i].friend_status=2; requests.items[i].photo_50=requests.items[i].photo_100; requests.items[i].photo_200=requests.items[i].photo_100; requests.items[i].photo_max_orig=requests.items[i].photo_100; requests.items[i].request_message=''; requests.items[i].message=''; requests.items[i].read_state=0; requests.items[i].mutual={count:0,users:[]}; i=i+1;} return {users:requests.items,friend_requests:{count:requests.count,items:requests.items}};",
            @"execute.loadWallComments":
                @"var comments=API.wall.getComments({owner_id:Args.owner_id,post_id:Args.post_id,count:Args.count,offset:Args.offset,extended:1}); return {post_comments:comments,comments:comments,users:comments.profiles,reply_to_users:comments.profiles,groups:comments.groups};",
            @"execute.loadPhotoComments":
                @"var comments=API.photos.getComments({owner_id:Args.owner_id,photo_id:Args.photo_id,count:Args.count,offset:Args.offset,extended:1}); return {comments:comments.items,users:comments.profiles,groups:comments.groups};",
            @"wall.addComment":
                @"return API.wall.createComment({owner_id:Args.owner_id,post_id:Args.post_id,message:Args.text,from_group:Args.from_group,attachments:Args.attachments});",
            @"newsfeed.getLists":
                @"return {count:0,items:[]};",
            @"groups.get":
                @"return API.groups.get({user_id:Args.user_id,count:5000,offset:0,filter:Args.filter,extended:1,fields:'photo_50,photo_100,photo_200,members_count,status,verified'});",
            @"friends.getRequests":
                @"var requests=API.friends.getRequests({count:Args.count,offset:Args.offset,extended:1,fields:'photo_50,photo_100,photo_200,online,friend_status'}); var i=0; while(i<requests.items.length){requests.items[i].user_id=requests.items[i].id; requests.items[i].friend_status=2; requests.items[i].photo_50=requests.items[i].photo_100; requests.items[i].photo_200=requests.items[i].photo_100; requests.items[i].photo_max_orig=requests.items[i].photo_100; requests.items[i].request_message=''; requests.items[i].message=''; requests.items[i].read_state=0; requests.items[i].mutual={count:0,users:[]}; i=i+1;} return requests;",
            @"notifications.get":
                @"var n=API.notifications.get({count:Args.count,offset:Args.offset,archived:1}); var raw_count=n.items.length; var keys=''; var i=0; while(i<raw_count){var x=n.items[i]; var key=''; if(x.type=='like_post' && x.parent){key=x.parent.to_id+'_'+x.parent.id;} if(x.type=='comment_post' && x.parent){key=x.parent.to_id+'_'+x.parent.id;} if(x.type=='copy_post' && x.parent){key=x.parent.to_id+'_'+x.parent.id;} if(x.type=='wall' && x.feedback){key=x.feedback.to_id+'_'+x.feedback.id;} if(key!=''){if(keys!=''){keys=keys+',';} keys=keys+key;} i=i+1;} var fresh=API.wall.getById({posts:keys}); var items=[]; i=0; while(i<raw_count){var item=n.items[i]; var post=null; var j=0; while(j<fresh.items.length){var candidate=fresh.items[j]; if(item.parent && candidate.id==item.parent.id && candidate.owner_id==item.parent.to_id){post=candidate;} if(item.type=='wall' && item.feedback && candidate.id==item.feedback.id && candidate.owner_id==item.feedback.to_id){post=candidate;} j=j+1;} if(item.type=='like_post' && post){item.parent=post; item.feedback.from_id=item.feedback.id; item.feedback={count:1,items:[item.feedback]}; items.push(item);} if(item.type=='wall' && post){item.feedback=post; items.push(item);} if(item.type=='comment_post' && post){var actor=item.feedback; var comments=API.wall.getComments({owner_id:post.owner_id,post_id:post.id,count:100,extended:1}); var best=null; j=0; while(j<comments.items.length){var comment=comments.items[j]; if(comment.from_id==actor.id && comment.date<=item.date && (!best || comment.date>best.date)){best=comment;} j=j+1;} if(best){item.parent=post; item.feedback=best; items.push(item);}} if(item.type=='comment_photo' && item.parent){var photoComments=API.photos.getComments({owner_id:item.parent.owner_id,photo_id:item.parent.id,count:100,extended:1}); var photoBest=null; j=0; while(j<photoComments.items.length){var photoComment=photoComments.items[j]; if(photoComment.date<=item.date && (!photoBest || photoComment.date>photoBest.date)){photoBest=photoComment;} j=j+1;} if(photoBest){item.feedback=photoBest; items.push(item);}} if(item.type=='copy_post' && post){var one=API.notifications.get({count:1,offset:Args.offset+i,archived:1}); if(one.profiles.length>0){var reposter=one.profiles[0]; reposter.from_id=reposter.uid; item.parent=post; item.feedback={count:1,items:[reposter]}; items.push(item);}} if(item.type=='sent_gift' && item.parent){var sender=item.parent; j=0; while(j<n.profiles.length){if(n.profiles[j].uid==sender.id){sender=n.profiles[j];} j=j+1;} var me=API.users.get({}); item.type='wall'; item.parent=null; item.feedback={id:0,post_id:0,owner_id:me[0].id,to_id:me[0].id,from_id:sender.uid,date:item.date,text:'Sent you a gift',attachments:[],comments:{count:0,can_post:0},likes:{count:0,user_likes:0,can_like:0},reposts:{count:0}}; items.push(item);} i=i+1;} n.items=items; n.count=items.length; n.new_offset=Args.offset+raw_count; n.next_from=''; return n;",
            @"newsfeed.getComments":
                @"var n=API.notifications.get({count:50,offset:0,archived:1}); var keys=''; var i=0; while(i<n.items.length){var x=n.items[i]; if(x.type=='comment_post' && x.parent){if(keys!=''){keys=keys+',';} keys=keys+x.parent.to_id+'_'+x.parent.id;} i=i+1;} var fresh=API.wall.getById({posts:keys}); var items=[]; var profiles=n.profiles; var groups=n.groups; i=0; while(i<n.items.length && items.length<Args.count){var item=n.items[i]; if(item.type=='comment_post' && item.parent){var post=null; var j=0; while(j<fresh.items.length){if(fresh.items[j].id==item.parent.id && fresh.items[j].owner_id==item.parent.to_id){post=fresh.items[j];} j=j+1;} if(post){var actor=item.feedback; var comments=API.wall.getComments({owner_id:post.owner_id,post_id:post.id,count:100,extended:1}); var best=null; j=0; while(j<comments.items.length){var comment=comments.items[j]; if(comment.from_id==actor.id && comment.date<=item.date && (!best || comment.date>best.date)){best=comment;} j=j+1;} if(best){post.type='post'; post.source_id=post.owner_id; post.comments={count:comments.count,can_post:comments.can_post,items:[best]}; items.push(post); profiles=profiles+comments.profiles; groups=groups+comments.groups;}}} i=i+1;} return {items:items,profiles:profiles,groups:groups,count:items.length,next_from:'',new_offset:items.length};",
            @"store.getProducts":
                @"return {count:0,items:[]};",
            @"account.registerDevice":
                @"return 1;",
            @"fave.getPhotos":
                @"return {count:0,items:[]};"
        };
    });

    for (NSString *method in scripts) {
        NSString *needle = [@"method/" stringByAppendingString:method];
        NSRange range = [value rangeOfString:needle];
        if (range.location == NSNotFound) {
            continue;
        }

        NSUInteger end = NSMaxRange(range);
        if (end < value.length) {
            unichar next = [value characterAtIndex:end];
            if (next != '?' && next != '#' && next != '/') {
                continue;
            }
        }

        NSString *replacement = @"method/execute";
        NSString *rewritten = [value stringByReplacingCharactersInRange:range
                                                               withString:replacement];
        NSString *separator = [rewritten rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
        NSString *script = [scripts[method] stringByReplacingOccurrencesOfString:@"album_id:-6"
                                                                       withString:@"album_id:'profile'"];
        rewritten = [rewritten stringByAppendingFormat:@"%@code=%@",
                      separator, OVKPercentEncode(script)];
        if ([method isEqualToString:@"execute.loadGroupsSuggested"] ||
            [method isEqualToString:@"groups.get"]) {
            rewritten = [rewritten stringByAppendingString:@"&ovk_groups_request=1"];
        }
        if ([method isEqualToString:@"execute.newsfeedGet"]) {
            rewritten = [rewritten stringByAppendingString:@"&ovk_newsfeed_request=1"];
        }
        OVKLogRequest([@"EMULATE " stringByAppendingString:method], rewritten, -1);
        return rewritten;
    }

    return value;
}

@interface OVKLongPollProtocol : NSURLProtocol
@property (nonatomic, assign) BOOL stopped;
@end

@implementation OVKLongPollProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    NSURL *url = request.URL;
    if ([url.query rangeOfString:@"ovk_bridge=1"].location != NSNotFound) return NO;
    return [url.host caseInsensitiveCompare:@"api.openvk.org"] == NSOrderedSame &&
           [url.path hasPrefix:@"/nim"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    NSString *timestamp = @"1";
    for (NSString *pair in [self.request.URL.query componentsSeparatedByString:@"&"]) {
        NSArray *parts = [pair componentsSeparatedByString:@"="];
        if (parts.count >= 2 && [parts[0] isEqualToString:@"ts"]) {
            timestamp = parts[1];
            break;
        }
    }

    NSString *json = [NSString stringWithFormat:@"{\"ts\":%@,\"updates\":[]}",
                      timestamp.length > 0 ? timestamp : @"1"];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *headers = @{
        @"Content-Type": @"application/json; charset=utf-8",
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length]
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL
        statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:headers];

    OVKLogRequest(@"LONGPOLL_WAIT", self.request.URL.absoluteString, 200);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.stopped) return;
        [self.client URLProtocol:self didReceiveResponse:response
              cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
    });
}

- (void)stopLoading
{
    self.stopped = YES;
}

@end

static NSString *OVKRewriteString(NSString *value)
{
    if (value == nil || value.length == 0) {
        return value;
    }

    NSString *rewritten = value;
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"api.vk.com"
                                                      withString:@"api.openvk.org"];
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"oauth.vk.com"
                                                      withString:@"api.openvk.org"];
    // VK for iPad 2.0.4 uses /token/, while OpenVK exposes the legacy
    // password grant at the strict /token route.
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"api.openvk.org/token/"
                                                      withString:@"api.openvk.org/token"];
    if ([rewritten rangeOfString:@"api.openvk.org/token"].location != NSNotFound &&
        [rewritten rangeOfString:@"client_name="].location == NSNotFound) {
        rewritten = [rewritten stringByAppendingString:
                     ([rewritten rangeOfString:@"?"].location == NSNotFound
                      ? @"?client_name=openvk_legacy_ios"
                      : @"&client_name=openvk_legacy_ios")];
    }
    // Avoid OpenVK's HTTP -> HTTPS redirect. CFNetwork on iOS 8 follows the
    // 301 as a GET and drops the POST body, including access_token.
    rewritten = [rewritten stringByReplacingOccurrencesOfString:@"http://api.openvk.org"
                                                      withString:@"https://api.openvk.org"];
    rewritten = OVKEmulateLegacyMethod(rewritten);
    if (![rewritten isEqualToString:value]) {
        OVKLogRequest(@"REWRITE", rewritten, -1);
    }
    return rewritten;
}

static NSURL *OVKRewriteURL(NSURL *url)
{
    if (url == nil) {
        return nil;
    }

    NSString *original = url.absoluteString;
    NSString *rewritten = OVKRewriteString(original);
    if ([rewritten isEqualToString:original]) {
        return url;
    }

    return [NSURL URLWithString:rewritten];
}

static BOOL OVKTrustIsForAPIHost(SecTrustRef trust)
{
    if (trust == NULL || SecTrustGetCertificateCount(trust) < 1) {
        return NO;
    }

    SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, 0);
    if (certificate == NULL) {
        return NO;
    }

    CFStringRef summary = SecCertificateCopySubjectSummary(certificate);
    if (summary == NULL) {
        return NO;
    }

    BOOL matches = [(__bridge NSString *)summary
        caseInsensitiveCompare:@"api.openvk.org"] == NSOrderedSame;
    CFRelease(summary);
    return matches;
}

// iOS versions before 10 do not ship the ISRG Root X1 certificate used by
// Let's Encrypt. Accept only the recoverable missing-root failure, and only
// when the leaf certificate belongs to the OpenVK API host.
%hookf(OSStatus, SecTrustEvaluate, SecTrustRef trust, SecTrustResultType *result)
{
    OSStatus status = %orig;
    if (status == errSecSuccess && result != NULL &&
        *result == kSecTrustResultRecoverableTrustFailure &&
        OVKTrustIsForAPIHost(trust)) {
        *result = kSecTrustResultProceed;
    }

    return status;
}

%hook NSURL

+ (instancetype)URLWithString:(NSString *)URLString
{
    return %orig(OVKRewriteString(URLString));
}

+ (instancetype)URLWithString:(NSString *)URLString relativeToURL:(NSURL *)baseURL
{
    return %orig(OVKRewriteString(URLString), OVKRewriteURL(baseURL));
}

- (instancetype)initWithString:(NSString *)URLString
{
    return %orig(OVKRewriteString(URLString));
}

- (instancetype)initWithString:(NSString *)URLString relativeToURL:(NSURL *)baseURL
{
    return %orig(OVKRewriteString(URLString), OVKRewriteURL(baseURL));
}

%end

%hook OVKDisabledLoginViewController

- (void)viewDidLoad
{
    %orig;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(18.0, 28.0, 210.0, 38.0);
    button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [button setTitle:[NSString stringWithFormat:@"Accounts · %@", OVKCurrentInstance()]
            forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    [button addTarget:self action:@selector(ovk_openAccounts:) forControlEvents:UIControlEventTouchUpInside];
    [[(id)self view] addSubview:button];
}

%new
- (void)ovk_openAccounts:(id)sender
{
    OVKPresentAccounts((UIViewController *)self);
}

%end

%hook OVKDisabledSettingsViewController

- (void)loadView
{
    %orig;
    OVKFeedbackControllerInstance = self;
    UIBarButtonItem *accounts = [[UIBarButtonItem alloc] initWithTitle:@"Accounts"
        style:UIBarButtonItemStylePlain target:self action:@selector(ovk_openAccounts:)];
    [(id)self navigationItem].rightBarButtonItem = accounts;
}

%new
- (void)ovk_openAccounts:(id)sender
{
    OVKPresentAccounts((UIViewController *)self);
}

%end

%hook iPadFriendRequestsCell

- (void)setRequest:(id)request
{
    %orig;

    NSNumber *userID = nil;
    @try {
        userID = [request valueForKey:@"user_id"];
    } @catch (__unused NSException *exception) {
        return;
    }
    if (userID == nil) return;

    NSString *avatarURL = nil;
    @synchronized (OVKUserAvatarURLs) {
        avatarURL = [OVKUserAvatarURLs objectForKey:[userID stringValue]];
    }
    if (avatarURL.length == 0) return;

    @try {
        id avatarImage = [(id)self valueForKey:@"avatarImage"];
        if ([avatarImage respondsToSelector:@selector(setImageWithPath:withFilter:)]) {
            [avatarImage setImageWithPath:avatarURL withFilter:nil];
        }
    } @catch (__unused NSException *exception) {
    }
}

%end

%hook iPadWallViewController

- (void)bigAvatarTap:(id)sender
{
    NSNumber *ownerID = OVKWallOwnerID(self);
    Class photoClass = NSClassFromString(@"VKPhoto");
    Class viewerClass = NSClassFromString(@"ImageViewer");
    if (!ownerID || !photoClass || !viewerClass) { %orig; return; }
    if ([objc_getAssociatedObject(self, &OVKAvatarLoadingKey) boolValue]) return;
    objc_setAssociatedObject(self, &OVKAvatarLoadingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    OVKLogRequest(@"AVATAR_ALBUM", [NSString stringWithFormat:@"owner=%@", ownerID], -1);

    NSString *fallbackURL = OVKWallAvatarURL(self);
    void (^showPhotos)(NSArray *) = ^(NSArray *photoDictionaries) {
        NSMutableArray *photos = [NSMutableArray array];
        for (NSDictionary *dictionary in photoDictionaries) {
            @try {
                NSMutableDictionary *safePhoto = [dictionary mutableCopy];
                NSString *medium = [safePhoto objectForKey:@"photo_807"] ?:
                                   [safePhoto objectForKey:@"photo_604"] ?:
                                   [safePhoto objectForKey:@"photo_510"];
                if (medium.length > 0) {
                    [safePhoto setObject:medium forKey:@"photo_1280"];
                    [safePhoto setObject:medium forKey:@"photo_2560"];
                    [safePhoto setObject:@[@{ @"type": @"x", @"url": medium, @"src": medium,
                                               @"width": @0, @"height": @0 }] forKey:@"sizes"];
                }
                if (![safePhoto objectForKey:@"likes"]) {
                    [safePhoto setObject:@{ @"count": @0, @"user_likes": @0, @"can_like": @0 } forKey:@"likes"];
                }
                if (![safePhoto objectForKey:@"comments"]) {
                    [safePhoto setObject:@{ @"count": @0, @"can_post": @0 } forKey:@"comments"];
                }
                id photo = [[photoClass alloc] initWithDictionary:safePhoto];
                if (photo) [photos addObject:photo];
            } @catch (__unused NSException *exception) {}
        }
        if (photos.count == 0 && fallbackURL.length > 0) {
            NSDictionary *fallback = @{
                @"id": @1, @"pid": @1, @"owner_id": ownerID, @"album_id": @(-6),
                @"date": @0, @"text": @"", @"photo_75": fallbackURL, @"photo_130": fallbackURL,
                @"photo_604": fallbackURL, @"photo_807": fallbackURL,
                @"photo_1280": fallbackURL, @"photo_2560": fallbackURL,
                @"likes": @{ @"count": @0, @"user_likes": @0, @"can_like": @0 },
                @"comments": @{ @"count": @0, @"can_post": @0 }
            };
            id photo = [[photoClass alloc] initWithDictionary:fallback];
            if (photo) [photos addObject:photo];
        }
        objc_setAssociatedObject(self, &OVKAvatarLoadingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (photos.count == 0) return;
        int index = (int)photos.count - 1;
        id viewer = [[viewerClass alloc] initWithAttachments:photos withIndex:index
                                             withTotalCount:(int)photos.count withAlbum:nil withUid:ownerID];
        [viewer showSelfInWindow];
    };

    if (ownerID.longLongValue < 0) {
        showPhotos(@[]);
        return;
    }
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:@"access_token"] ?: @"";
    NSString *urlString = [NSString stringWithFormat:
        @"https://api.openvk.org/method/photos.get?owner_id=%@&album_id=profile&count=50&photo_sizes=1&extended=1&access_token=%@",
        ownerID, OVKPercentEncode(token)];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
        NSDictionary *root = data.length > 0
            ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
        NSArray *items = [[root objectForKey:@"response"] objectForKey:@"items"];
        dispatch_async(dispatch_get_main_queue(), ^{ showPhotos([items isKindOfClass:[NSArray class]] ? items : @[]); });
    });
}

%end

%hook iPadNewsViewController

- (void)loadUserLists
{
    Class infoClass = NSClassFromString(@"NewsfeedInfo");
    if (!infoClass) { %orig; return; }
    id myNews = [[infoClass alloc] initWithName:@"My news" andSourceId:@"my"];
    id globalNews = [[infoClass alloc] initWithName:@"Global news" andSourceId:@"global"];
    NSMutableArray *feeds = [NSMutableArray arrayWithObjects:myNews, globalNews, nil];
    if (!objc_getAssociatedObject(self, &OVKNewsInitializedKey)) {
        objc_setAssociatedObject(self, &OVKNewsInitializedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:OVKGlobalNewsSelectionKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    @try {
        [(id)self setValue:feeds forKey:@"newsfeedInfos"];
        [(id)self setValue:@0 forKey:@"currentNewsfeed"];
        [(id)self setCurrentFeedTitle];
    } @catch (NSException *exception) {
        OVKLogRequest(@"NEWS_LISTS_ERROR", exception.reason, -1);
    }
}

- (void)newsfeedListsControllerDidSelectFeedIndex:(NSInteger)index
{
    OVKSelectedGlobalNews = index == 1;
    [[NSUserDefaults standardUserDefaults] setBool:OVKSelectedGlobalNews forKey:OVKGlobalNewsSelectionKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    OVKLogRequest(@"NEWS_PICK", OVKSelectedGlobalNews ? @"global" : @"my", -1);
    %orig;
}

- (id)loadNewsFeed:(id)feed from:(id)from count:(id)count startTime:(id)startTime
{
    NSString *sourceID = nil;
    @try { sourceID = [feed valueForKey:@"sourceId"]; }
    @catch (__unused NSException *exception) {}
    BOOL previous = OVKLoadingGlobalNews;
    OVKLoadingGlobalNews = OVKSelectedGlobalNews || [sourceID isEqualToString:@"global"];
    id request = %orig;
    OVKLoadingGlobalNews = previous;
    return request;
}

%end

%hook iPadFeedbackViewController

%new
- (void)ovk_forceFeedbackRefresh
{
    SEL pullRefresh = NSSelectorFromString(@"reloadFeedback:");
    if ([(id)self respondsToSelector:pullRefresh]) {
        OVKLogRequest(@"FEEDBACK_REFRESH", @"reloadFeedback:", -1);
        id refreshView = nil;
        @try { refreshView = [(id)self valueForKey:@"pullToRefreshView"]; }
        @catch (__unused NSException *exception) {}
        ((void (*)(id, SEL, id))objc_msgSend)(self, pullRefresh, refreshView);
        return;
    }
    SEL stopAndReload = NSSelectorFromString(@"stopAndReload");
    if ([(id)self respondsToSelector:stopAndReload]) {
        OVKLogRequest(@"FEEDBACK_REFRESH", @"stopAndReload", -1);
        ((void (*)(id, SEL))objc_msgSend)(self, stopAndReload);
        return;
    }
    OVKLogRequest(@"FEEDBACK_REFRESH", @"update fallback", -1);
    [(id)self update];
}

%new
- (void)ovk_refreshFeedbackWhenReady:(NSNumber *)attemptNumber
{
    NSUInteger attempt = [attemptNumber unsignedIntegerValue];
    BOOL reloading = NO;
    @try { reloading = [[(id)self valueForKey:@"reloading"] boolValue]; }
    @catch (__unused NSException *exception) {}
    OVKLogRequest(@"FEEDBACK_WAIT", [NSString stringWithFormat:@"attempt=%lu reloading=%d",
                  (unsigned long)attempt, reloading], -1);
    if (reloading && attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, id))objc_msgSend)(self,
                NSSelectorFromString(@"ovk_refreshFeedbackWhenReady:"), @(attempt + 1));
        });
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"ovk_forceFeedbackRefresh"));
}

- (void)loadView
{
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ovk_notificationArrived:)
        name:OVKBridgeNotificationArrived object:nil];
}

%new
- (void)ovk_notificationArrived:(NSNotification *)notification
{
    // Never reload from a broker callback. In this iPad build the feedback
    // controller remains attached while hidden; reloading it here marks the
    // event viewed, clears the badge, and still leaves the hidden list stale.
    OVKFeedbackNeedsRefresh = YES;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:OVKBridgeNotificationArrived object:nil];
    %orig;
}

%end

%hook SettingsViewController

- (id)prepareSections
{
    id prepared = %orig;
    NSArray *sections = nil;
    id sectionIndex = nil;
    if ([prepared isKindOfClass:[NSArray class]]) {
        sections = prepared;
    } else {
        sectionIndex = prepared;
        @try { sections = [prepared valueForKey:@"sections"]; }
        @catch (__unused NSException *exception) {}
    }
    if (![sections isKindOfClass:[NSArray class]]) return prepared;
    NSMutableArray *visible = [NSMutableArray array];
    for (id section in sections) {
        NSString *title = nil;
        @try { title = [section valueForKey:@"title"]; }
        @catch (__unused NSException *exception) {}
        BOOL images = title && [title caseInsensitiveCompare:@"Images"] == NSOrderedSame;
        BOOL other = title && [title caseInsensitiveCompare:@"Other"] == NSOrderedSame;
        if (!images && !other) [visible addObject:section];
    }
    if ([prepared isKindOfClass:[NSArray class]]) return visible;
    @try { [sectionIndex setValue:visible forKey:@"sections"]; }
    @catch (__unused NSException *exception) {}
    return prepared;
}

%end

%hook PhotofeedViewController

- (void)loadView
{
    %orig;
    UISegmentedControl *control = nil;
    @try { control = [(id)self valueForKey:@"barViewSegment"]; }
    @catch (__unused NSException *exception) {}
    if (![control isKindOfClass:[UISegmentedControl class]]) return;
    NSInteger myIndex = control.numberOfSegments > 1 ? 1 : 0;
    for (NSInteger index = 0; index < control.numberOfSegments; index++) {
        NSString *title = [control titleForSegmentAtIndex:index];
        if (title && [title rangeOfString:@"my" options:NSCaseInsensitiveSearch].location != NSNotFound) myIndex = index;
    }
    control.selectedSegmentIndex = myIndex;
    control.hidden = YES;
    [(id)self performSelector:@selector(selectTab)];
}

- (void)selectTab
{
    UISegmentedControl *control = nil;
    @try { control = [(id)self valueForKey:@"barViewSegment"]; }
    @catch (__unused NSException *exception) {}
    if ([control isKindOfClass:[UISegmentedControl class]]) {
        NSInteger myIndex = control.numberOfSegments > 1 ? 1 : 0;
        for (NSInteger index = 0; index < control.numberOfSegments; index++) {
            NSString *title = [control titleForSegmentAtIndex:index];
            if (title && [title rangeOfString:@"my" options:NSCaseInsensitiveSearch].location != NSNotFound) myIndex = index;
        }
        control.selectedSegmentIndex = myIndex;
        control.hidden = YES;
    }
    %orig;
}

%end

%hook ProfilePhotoVideoView

- (void)setVideo:(id)video
{
    %orig;

    NSInteger duration = 0;
    @try { duration = [[video valueForKey:@"duration"] integerValue]; }
    @catch (__unused NSException *exception) { return; }
    if (duration > 0) return;

    NSString *urlString = OVKBestVideoURL(video);
    if (urlString.length == 0) return;

    NSNumber *cached = nil;
    @synchronized (OVKVideoDurations) { cached = [OVKVideoDurations objectForKey:urlString]; }
    if (cached.integerValue > 0) {
        @try { [video setValue:cached forKey:@"duration"]; } @catch (__unused NSException *exception) {}
        [(id)self setVideoDuration:cached.integerValue];
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    __weak id weakSelf = self;
    __weak id weakVideo = video;
    [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"duration" error:&error] != AVKeyValueStatusLoaded) return;
        NSTimeInterval raw = CMTimeGetSeconds(asset.duration);
        if (!isfinite(raw) || raw <= 0.0) return;
        NSInteger seconds = MAX(1, (NSInteger)llround(raw));
        NSNumber *value = @(seconds);
        @synchronized (OVKVideoDurations) { [OVKVideoDurations setObject:value forKey:urlString]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            id view = weakSelf;
            id currentVideo = weakVideo;
            if (!view || !currentVideo) return;
            @try { [currentVideo setValue:value forKey:@"duration"]; }
            @catch (__unused NSException *exception) {}
            [view setVideoDuration:seconds];
        });
    }];
}

%end

%hook iPadGroupsViewController

- (void)tableSection:(id)section selectorClicked:(id)sender
{
    UISegmentedControl *control = nil;
    @try { control = [(id)self valueForKey:@"adminSegmeng"]; }
    @catch (__unused NSException *exception) {}
    NSInteger selection = [control isKindOfClass:[UISegmentedControl class]] ? control.selectedSegmentIndex : 0;
    if ([sender respondsToSelector:@selector(integerValue)]) selection = [sender integerValue];
    OVKGroupsManagementMode = selection == 1;
    OVKLogRequest(@"GROUPS_SELECTOR", [NSString stringWithFormat:@"selection=%ld sender=%@ section=%@",
                  (long)selection, sender, section], -1);
    BOOL previous = OVKBuildingGroupsSelector;
    OVKBuildingGroupsSelector = YES;
    %orig;
    OVKBuildingGroupsSelector = previous;
}

- (void)updateDataSources
{
    @try {
        [[(id)self valueForKey:@"getEventsArray"] removeAllObjects];
        [[(id)self valueForKey:@"getEventsPastArray"] removeAllObjects];
    } @catch (__unused NSException *exception) {}
    %orig;
}

%end

%hook UIActionSheet

- (NSInteger)addButtonWithTitle:(NSString *)title
{
    if (OVKBuildingGroupsSelector && title &&
        [title rangeOfString:@"event" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        OVKLogRequest(@"GROUPS_HIDE_OPTION", title, -1);
        return -1;
    }
    return %orig;
}

%end

%hook SidebarMenuController

- (void)selectRow:(int)row userInteraction:(BOOL)userInteraction
{
    Ivar ivar = class_getInstanceVariable([(id)self class], "_sections");
    if (!ivar) ivar = class_getInstanceVariable([(id)self class], "sections");
    NSUInteger feedbackRow = NSUIntegerMax;
    NSUInteger messagesRow = NSUIntegerMax;
    if (ivar) {
        OVKSidebarSections *sections = (OVKSidebarSections *)((uint8_t *)(__bridge void *)self + ivar_getOffset(ivar));
        feedbackRow = sections->feedback;
        messagesRow = sections->messages;
    }
    OVKFeedbackSectionSelected = ((NSUInteger)row == feedbackRow);
    OVKLogRequest(@"SIDEBAR_SELECT", [NSString stringWithFormat:@"row=%d feedback=%lu selected=%d interaction=%d",
                  row, (unsigned long)feedbackRow, OVKFeedbackSectionSelected, userInteraction], -1);
    if (OVKFeedbackSectionSelected && OVKFeedbackNeedsRefresh) {
        // The legacy controller keeps a stale data source even when its update
        // request succeeds. Evict it before selection so iPadMain builds a new
        // controller and follows the reliable initial-load path.
        id parent = nil;
        SEL parentSelector = NSSelectorFromString(@"parentMain");
        if ([(id)self respondsToSelector:parentSelector]) {
            parent = ((id (*)(id, SEL))objc_msgSend)(self, parentSelector);
        }
        SEL setter = NSSelectorFromString(@"setFeedbackView:");
        if (parent && [parent respondsToSelector:setter]) {
            ((void (*)(id, SEL, id))objc_msgSend)(parent, setter, nil);
            OVKFeedbackControllerInstance = nil;
            OVKLogRequest(@"FEEDBACK_EVICT", @"setFeedbackView:nil", -1);
        }
        OVKFeedbackNeedsRefresh = NO;
        OVKPendingNotificationCount = 0;
        OVKUpdateFeedbackBadge();
    }
    if ((NSUInteger)row == messagesRow) {
        if (OVKMessagesNeedRefresh) {
            id parent = nil;
            SEL parentSelector = NSSelectorFromString(@"parentMain");
            if ([(id)self respondsToSelector:parentSelector]) {
                parent = ((id (*)(id, SEL))objc_msgSend)(self, parentSelector);
            }
            SEL setter = NSSelectorFromString(@"setMessagesView:");
            if (parent && [parent respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(parent, setter, nil);
                OVKLogRequest(@"MESSAGES_EVICT", @"setMessagesView:nil", -1);
            }
            OVKMessagesNeedRefresh = NO;
        }
        OVKPendingMessageCount = 0;
        OVKUpdateMessagesBadge();
    }
    %orig;
}

- (void)initSections
{
    %orig;
    OVKSidebarControllerInstance = self;
    Ivar ivar = class_getInstanceVariable([(id)self class], "_sections");
    if (!ivar) ivar = class_getInstanceVariable([(id)self class], "sections");
    if (!ivar) return;
    OVKSidebarSections *sections = (OVKSidebarSections *)((uint8_t *)(__bridge void *)self + ivar_getOffset(ivar));
    NSUInteger removed = sections->favorites;
    if (removed >= sections->count) return;
    if (sections->settings > removed) sections->settings--;
    if (sections->support > removed) sections->support--;
    sections->favorites = NSUIntegerMax;
    sections->count--;
}

%end

%hook MessagesView

- (void)didMoveToWindow
{
    %orig;
    UIView *view = (UIView *)self;
    if (view.window) OVKVisibleMessagesView = self;
    else if (OVKVisibleMessagesView == self) OVKVisibleMessagesView = nil;
}

%end

%hook iPadChatViewController

- (void)messageWasSent:(id)payload
{
    NSMutableString *summary = [NSMutableString stringWithFormat:@"payload=%@", payload ? NSStringFromClass([payload class]) : @"nil"];
    if ([payload respondsToSelector:@selector(name)]) {
        @try { [summary appendFormat:@" name=%@", [payload valueForKey:@"name"]]; }
        @catch (__unused NSException *exception) {}
    }
    if ([payload respondsToSelector:@selector(object)]) {
        @try {
            id object = [payload valueForKey:@"object"];
            [summary appendFormat:@" object=%@ value=%@", object ? NSStringFromClass([object class]) : @"nil", object];
        } @catch (__unused NSException *exception) {}
    }
    if ([payload respondsToSelector:@selector(userInfo)]) {
        @try { [summary appendFormat:@" userInfo=%@", [payload valueForKey:@"userInfo"]]; }
        @catch (__unused NSException *exception) {}
    }
    OVKLogRequest(@"MESSAGE_CALLBACK", summary, -1);
    %orig;
}

- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    OVKVisibleChatController = self;
}

- (void)viewDidDisappear:(BOOL)animated
{
    if (OVKVisibleChatController == self) OVKVisibleChatController = nil;
    %orig;
}

%end

%hook NSHTTPURLResponse

- (NSInteger)statusCode
{
    NSInteger status = %orig;
    NSString *url = self.URL.absoluteString;
    if (status >= 400 && [url rangeOfString:@"openvk.org"].location != NSNotFound) {
        OVKLogRequest(@"RESPONSE", url, status);
    }
    return status;
}

%end

%hook NSMutableURLRequest

- (void)setURL:(NSURL *)URL
{
    %orig(OVKRewriteURL(URL));
}

- (void)setHTTPBody:(NSData *)body
{
    NSString *form = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    NSString *requestURL = self.URL.absoluteString;
    // friends_get_res in this iPad build discards the total count and never
    // asks for a second page. Request the complete list while preserving the
    // native friends.get response shape.
    if ([requestURL rangeOfString:@"/method/friends.get"].location != NSNotFound && form.length > 0) {
        NSArray *originalParts = [form componentsSeparatedByString:@"&"];
        NSMutableArray *translated = [NSMutableArray arrayWithCapacity:originalParts.count + 2];
        BOOL sawCount = NO;
        BOOL sawOffset = NO;
        for (NSString *part in originalParts) {
            if ([part hasPrefix:@"count="]) {
                [translated addObject:@"count=5000"];
                sawCount = YES;
            } else if ([part hasPrefix:@"offset="]) {
                [translated addObject:@"offset=0"];
                sawOffset = YES;
            } else {
                [translated addObject:part];
            }
        }
        if (!sawCount) [translated addObject:@"count=5000"];
        if (!sawOffset) [translated addObject:@"offset=0"];
        form = [translated componentsJoinedByString:@"&"];
        body = [form dataUsingEncoding:NSUTF8StringEncoding];
        OVKLogRequest(@"FRIENDS_ALL", @"count=5000 offset=0", -1);
    }
    if ([requestURL rangeOfString:@"ovk_newsfeed_request=1"].location != NSNotFound &&
        form.length > 0) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *part in [form componentsSeparatedByString:@"&"]) {
            if (![part hasPrefix:@"ovk_global="]) [parts addObject:part];
        }
        BOOL useGlobalNews = [[NSUserDefaults standardUserDefaults] boolForKey:OVKGlobalNewsSelectionKey] ||
                             OVKSelectedGlobalNews || OVKLoadingGlobalNews;
        if (useGlobalNews) [parts addObject:@"ovk_global=1"];
        form = [parts componentsJoinedByString:@"&"];
        body = [form dataUsingEncoding:NSUTF8StringEncoding];
        OVKLogRequest(@"NEWS_SOURCE", useGlobalNews ? @"global" : @"my", -1);
    }
    if ([requestURL rangeOfString:@"/method/photos.get"].location != NSNotFound && form.length > 0) {
        NSMutableArray *parts = [NSMutableArray array];
        BOOL changed = NO;
        for (NSString *part in [form componentsSeparatedByString:@"&"]) {
            if ([part isEqualToString:@"album_id=-6"] || [part isEqualToString:@"album_id=%2D6"]) {
                [parts addObject:@"album_id=profile"];
                changed = YES;
            } else {
                [parts addObject:part];
            }
        }
        if (changed) {
            form = [parts componentsJoinedByString:@"&"];
            body = [form dataUsingEncoding:NSUTF8StringEncoding];
            OVKLogRequest(@"PROFILE_ALBUM", @"album_id=profile", -1);
        }
    }
    if ([requestURL rangeOfString:@"/method/messages."].location != NSNotFound && form.length > 0) {
        NSMutableArray *parts = [NSMutableArray array];
        BOOL hasUserID = NO;
        BOOL hasMessage = NO;
        for (NSString *part in [form componentsSeparatedByString:@"&"]) {
            if ([part hasPrefix:@"user_id="]) hasUserID = YES;
            if ([part hasPrefix:@"message="]) hasMessage = YES;
        }
        for (NSString *part in [form componentsSeparatedByString:@"&"]) {
            if (!hasUserID && [part hasPrefix:@"uid="]) {
                [parts addObject:[@"user_id=" stringByAppendingString:[part substringFromIndex:4]]];
            } else if (!hasMessage && ([part hasPrefix:@"body="] || [part hasPrefix:@"text="])) {
                NSRange equals = [part rangeOfString:@"="];
                [parts addObject:[@"message=" stringByAppendingString:[part substringFromIndex:NSMaxRange(equals)]]];
                hasMessage = YES;
            } else {
                [parts addObject:part];
            }
        }
        form = [parts componentsJoinedByString:@"&"];
        body = [form dataUsingEncoding:NSUTF8StringEncoding];
        OVKLogRequest(@"MESSAGES_PARAMS", @"legacy aliases normalized", -1);
    }
    BOOL managedGroupsRequest = OVKGroupsManagementMode;
    if ([requestURL rangeOfString:@"ovk_groups_request=1"].location != NSNotFound) {
        for (NSString *part in [form componentsSeparatedByString:@"&"]) {
            if (![part hasPrefix:@"filter="]) continue;
            NSString *filter = [[part substringFromIndex:7] stringByRemovingPercentEncoding].lowercaseString;
            if ([filter rangeOfString:@"admin"].location != NSNotFound ||
                [filter rangeOfString:@"editor"].location != NSNotFound ||
                [filter rangeOfString:@"moder"].location != NSNotFound) managedGroupsRequest = YES;
        }
    }
    if (managedGroupsRequest &&
        [requestURL rangeOfString:@"ovk_groups_request=1"].location != NSNotFound && form.length > 0) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *part in [form componentsSeparatedByString:@"&"]) {
            if (![part hasPrefix:@"filter="]) [parts addObject:part];
        }
        [parts addObject:@"filter=admin"];
        form = [parts componentsJoinedByString:@"&"];
        body = [form dataUsingEncoding:NSUTF8StringEncoding];
        OVKLogRequest(@"GROUPS_MANAGEMENT", @"filter=admin", -1);
    }
    BOOL isPasswordGrant = [form rangeOfString:@"grant_type=password"].location != NSNotFound ||
                           ([form rangeOfString:@"username="].location != NSNotFound &&
                            [form rangeOfString:@"password="].location != NSNotFound);
    if ([requestURL rangeOfString:@"/token"].location != NSNotFound || isPasswordGrant) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *part in [form componentsSeparatedByString:@"&"]) {
            if (![part hasPrefix:@"client_name="]) [parts addObject:part];
        }
        [parts addObject:@"client_name=openvk_legacy_ios"];
        form = [parts componentsJoinedByString:@"&"];
        body = [form dataUsingEncoding:NSUTF8StringEncoding];
    }
    %orig(body);
    if (form.length > 0) {
        NSMutableArray *safe = [NSMutableArray array];
        for (NSString *part in [form componentsSeparatedByString:@"&"]) {
            NSString *key = [[part componentsSeparatedByString:@"="] firstObject];
            if ([@[@"user_id", @"uid", @"owner_id", @"group_id", @"post_id", @"video_id", @"source_ids", @"list_id", @"filter"] containsObject:key]) {
                [safe addObject:part];
            }
        }
        if (safe.count > 0) OVKLogRequest(@"PARAMS", [safe componentsJoinedByString:@"&"], -1);
    }
}

%end

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)options error:(NSError **)error
{
    id object = OVKNormalizeJSON(%orig);
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSString *token = [object objectForKey:@"access_token"];
        id rawUserID = [object objectForKey:@"user_id"];
        if (token.length > 0 && [rawUserID respondsToSelector:@selector(longLongValue)]) {
            NSNumber *userID = @([rawUserID longLongValue]);
            NSString *secret = [object objectForKey:@"secret"];
            OVKStoreAccount(OVKCurrentInstance(), token, userID, secret, nil);
        }
        NSArray *executeErrors = [object objectForKey:@"execute_errors"];
        if (executeErrors.count > 0) {
            OVKLogRequest(@"EXECUTE_ERRORS", [executeErrors description], -1);
        }
    }
    return object;
}

%end

%ctor
{
    OVKUserAvatarURLs = [[NSMutableDictionary alloc] init];
    OVKVideoDurations = [[NSMutableDictionary alloc] init];
    OVKNotificationPollerInstance = [[OVKNotificationPoller alloc] init];
    [(OVKNotificationPoller *)OVKNotificationPollerInstance start];
    // The independent /nim client is disabled until incoming messages can be
    // appended through the chat's native single-message update path. Reloading
    // whole controllers from its callback caused delayed crashes.
    OVKMessagePollerInstance = [[OVKMessagePoller alloc] init];
    [(OVKMessagePoller *)OVKMessagePollerInstance start];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ OVKDumpMessagingRuntime(); });
    NSSetUncaughtExceptionHandler(&OVKUncaughtExceptionHandler);
    // Keep the response shape known to this client, but wait like a real
    // long-poll request. An immediate stub caused a hot retry loop; passing
    // modern OpenVK events through can crash this pre-v3 parser.
    // Do not pass OpenVK /nim events into this old parser directly: although
    // they use legacy event numbers, this iPad build crashes while decoding
    // their extended payload. Realtime messages are handled outside it.
    [NSURLProtocol registerClass:[OVKLongPollProtocol class]];
    // Keep movie audio alive under the iPad's legacy player and hardware
    // silent switch. This is harmless if the player configures it again.
    AVAudioSession *audio = [AVAudioSession sharedInstance];
    [audio setCategory:AVAudioSessionCategoryPlayback error:nil];
    [audio setActive:YES error:nil];
}
