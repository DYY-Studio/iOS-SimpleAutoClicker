#import <UIKit/UIKit.h>
#include <dlfcn.h>
#import "ZSFakeTouch/ZSFakeTouchDome/ZSFakeTouch/ZSFakeTouch.h"

// --- 预设 10 个点的数据模型 ---
@interface TapPointModel : NSObject
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) CGFloat x;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, strong) UIView *indicatorView; // 屏幕上的指示红点
@property (nonatomic, strong) UISlider *xSlider;
@property (nonatomic, strong) UISlider *ySlider;

- (NSDictionary *)toDictionary;
- (void)updateWithDictionary:(NSDictionary *)dict;
@end

@implementation TapPointModel
- (NSDictionary *)toDictionary {
    return @{
        @"isEnabled": @(self.isEnabled),
        @"x": @(self.x),
        @"y": @(self.y)
    };
}

- (void)updateWithDictionary:(NSDictionary *)dict {
    if (!dict) return;
    self.isEnabled = [dict[@"isEnabled"] boolValue];
    self.x = [dict[@"x"] floatValue];
    self.y = [dict[@"y"] floatValue];
}
@end

@interface FloatingOverlayWindow : UIWindow
@end

@implementation FloatingOverlayWindow
// 重写 hitTest，实现除了面板和按钮之外的区域点击穿透
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self) {
        return nil; // 点在空白区域，事件穿透到下层 App
    }
    return hitView;
}

- (BOOL)_canAffectStatusBarAppearance {
    return NO;
}
@end

@interface AutoClickerManager : NSObject
@property (nonatomic, strong) FloatingOverlayWindow *overlayWindow;
@property (nonatomic, strong) UIView *controlBar;       // 悬浮控制栏
@property (nonatomic, strong) UIView *settingsPanel;    // 设置面板
@property (nonatomic, strong) UIButton *toggleBtn;      // 启动/停止按钮
@property (nonatomic, strong) UILabel *intervalLbl;
@property (nonatomic, strong) UILabel *durationLbl;
@property (nonatomic, strong) UISlider *intervalSlider;
@property (nonatomic, strong) UISlider *durationSlider;
@property (nonatomic, strong) NSMutableArray<TapPointModel *> *points;
@property (nonatomic, assign) CGFloat clickInterval;    // 全局点击间隔 (秒)
@property (nonatomic, assign) CGFloat clickDuration;	// 点击时长 (秒)
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) dispatch_source_t timer;  // GCD定时器
+ (instancetype)sharedInstance;
- (void)setupUI;
@end

@implementation AutoClickerManager

+ (instancetype)sharedInstance {
    static AutoClickerManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AutoClickerManager alloc] init];
    });
    return instance;
}

- (NSString *)settingsKeyForCurrentApp {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID) bundleID = @"unknown_app";
    return [NSString stringWithFormat:@"AutoClicker_Settings_%@", bundleID];
}

// 保存设置
- (void)saveSettings {
    NSMutableArray *pointsArray = [NSMutableArray array];
    for (TapPointModel *model in self.points) {
        [pointsArray addObject:[model toDictionary]];
    }
    
    NSDictionary *settings = @{
        @"clickInterval": @(self.clickInterval),
		@"clickDuration": @(self.clickDuration),
        @"points": pointsArray
    };
    
    [[NSUserDefaults standardUserDefaults] setObject:settings forKey:[self settingsKeyForCurrentApp]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// 读取设置
- (void)loadSettings {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:[self settingsKeyForCurrentApp]];
    
    if (settings) {
        // 如果有保存的记录，就读取
        if (settings[@"clickInterval"]) {
            self.clickInterval = [settings[@"clickInterval"] floatValue];
        }
		if (settings[@"clickDuration"]) {
			self.clickDuration = [settings[@"clickDuration"] floatValue];
		}
        
        NSArray *pointsArray = settings[@"points"];
        if (pointsArray && pointsArray.count == 10) {
            for (int i = 0; i < 10; i++) {
                [self.points[i] updateWithDictionary:pointsArray[i]];
            }
        }
    } else {
        self.clickInterval = 0.1;
		self.clickDuration = 0.03;
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        for (int i = 0; i < 10; i++) {
            self.points[i].isEnabled = NO;
            self.points[i].x = screenSize.width / 2;
            self.points[i].y = screenSize.height / 2;
        }
    }
	[self clampIntervalToDuration];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _clickInterval = 0.1; // 默认 0.1 秒
		_clickDuration = 0.03; // 默认 0.03 秒
        _points = [NSMutableArray array];
        for (int i = 0; i < 10; i++) {
            [_points addObject:[[TapPointModel alloc] init]];
        }
		[self loadSettings];
    }
    return self;
}

- (void)setupUI {
    if (self.overlayWindow) return;
    
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    
    // 1. 初始化穿透 Window
    self.overlayWindow = [[FloatingOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 2;
    self.overlayWindow.hidden = NO;
    self.overlayWindow.backgroundColor = [UIColor clearColor];

    // 2. 初始化预设点位的视觉指示器 (初始隐藏)
    for (int i = 0; i < 10; i++) {
        TapPointModel *model = self.points[i];
        UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
        indicator.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.6];
        indicator.layer.cornerRadius = 10;
        indicator.center = CGPointMake(model.x, model.y);
        indicator.hidden = !model.isEnabled;
        indicator.userInteractionEnabled = NO; // 不阻挡点击
        
        UILabel *numLbl = [[UILabel alloc] initWithFrame:indicator.bounds];
        numLbl.text = [NSString stringWithFormat:@"%d", i+1];
        numLbl.textColor = [UIColor whiteColor];
        numLbl.textAlignment = NSTextAlignmentCenter;
        numLbl.font = [UIFont boldSystemFontOfSize:12];
        [indicator addSubview:numLbl];
        
        [self.overlayWindow addSubview:indicator];
        model.indicatorView = indicator;
    }
    
	CGFloat panelMaxWidth = MIN(screenSize.width - 40, 350);
    CGFloat panelMaxHeight = MIN(screenSize.height - 80, 650);

    // 3. 设置面板 (隐藏状态)
    self.settingsPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelMaxWidth, panelMaxHeight)];
	self.settingsPanel.center = self.overlayWindow.center;
    self.settingsPanel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.5];
    self.settingsPanel.layer.cornerRadius = 15;
    self.settingsPanel.hidden = YES;
	self.settingsPanel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | 
                                          UIViewAutoresizingFlexibleRightMargin | 
                                          UIViewAutoresizingFlexibleTopMargin | 
                                          UIViewAutoresizingFlexibleBottomMargin;
    [self.overlayWindow addSubview:self.settingsPanel];
    
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.settingsPanel.bounds];
	scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.settingsPanel addSubview:scrollView];
    
    CGFloat currentY = 20;
    
    // 全局间隔设置
    self.intervalLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 200, 30)];
    self.intervalLbl.text = [NSString stringWithFormat:@"全局点击间隔: %.2f s", self.clickInterval];
    self.intervalLbl.textColor = [UIColor whiteColor];
    [scrollView addSubview:self.intervalLbl];
    
    self.intervalSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, currentY + 30, scrollView.frame.size.width - 40, 30)];
    self.intervalSlider.minimumValue = 0.05;
    self.intervalSlider.maximumValue = 2.0;
    self.intervalSlider.value = self.clickInterval;
	self.intervalSlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.intervalSlider addTarget:self action:@selector(intervalChanged:) forControlEvents:UIControlEventValueChanged];
    [scrollView addSubview:self.intervalSlider];
    
    currentY += 80;

	// 全局点击时长设置
	self.durationLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 200, 30)];
	self.durationLbl.text = [NSString stringWithFormat:@"单次点击时长: %.4f s", self.clickDuration];
	self.durationLbl.textColor = [UIColor whiteColor];
	[scrollView addSubview:self.durationLbl];

	self.durationSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, currentY + 30, scrollView.frame.size.width - 40, 30)];
	self.durationSlider.minimumValue = 0.0;
	self.durationSlider.maximumValue = 0.10;
	self.durationSlider.value = self.clickDuration;
	self.durationSlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self.durationSlider addTarget:self action:@selector(durationChanged:) forControlEvents:UIControlEventValueChanged];
	[scrollView addSubview:self.durationSlider];

	currentY += 80;
    
    // 10个点的设置生成
    for (int i = 0; i < 10; i++) {
		TapPointModel *model = self.points[i];

        UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 100, 30)];
        titleLbl.text = [NSString stringWithFormat:@"点位 %d", i+1];
        titleLbl.textColor = [UIColor whiteColor];
        titleLbl.font = [UIFont boldSystemFontOfSize:16];
        [scrollView addSubview:titleLbl];
        
        UISwitch *enableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(120, currentY, 50, 30)];
        enableSwitch.tag = i;
		enableSwitch.on = model.isEnabled;
        [enableSwitch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:enableSwitch];
        
        currentY += 40;

		// X 轴标签
		UILabel *xLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 30, 30)];
		xLbl.text = @"X";
		xLbl.textColor = [UIColor whiteColor];
		xLbl.font = [UIFont boldSystemFontOfSize:16];
		[scrollView addSubview:xLbl];

        // X 轴滑块
        UISlider *xSlider = [[UISlider alloc] initWithFrame:CGRectMake(20 + 30, currentY, scrollView.frame.size.width - 40 - 30, 30)];
        xSlider.minimumValue = 0;
        xSlider.maximumValue = screenSize.width;
        xSlider.value = model.x;
        xSlider.tag = 100 + i; // 加 100 区分 X
		xSlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [xSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:xSlider];
		// [self.xSliders addObject:xSlider];
		model.xSlider = xSlider;
        
        currentY += 40;

		// Y 轴标签
		UILabel *yLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 30, 30)];
		yLbl.text = @"Y";
		yLbl.textColor = [UIColor whiteColor];
		yLbl.font = [UIFont boldSystemFontOfSize:16];
		[scrollView addSubview:yLbl];
        
        // Y 轴滑块
        UISlider *ySlider = [[UISlider alloc] initWithFrame:CGRectMake(20 + 30, currentY, scrollView.frame.size.width - 40 - 30, 30)];
        ySlider.minimumValue = 0;
        ySlider.maximumValue = screenSize.height;
        ySlider.value = model.y;
        ySlider.tag = 200 + i; // 加 200 区分 Y
		ySlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [ySlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:ySlider];
		// [self.ySliders addObject:ySlider];
		model.ySlider = ySlider;
        
        currentY += 40;
        
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, currentY, scrollView.frame.size.width - 20, 1)];
        line.backgroundColor = [UIColor darkGrayColor];
		line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [scrollView addSubview:line];
        
        currentY += 20;
    }
    scrollView.contentSize = CGSizeMake(scrollView.frame.size.width, currentY);
    
    // 4. 悬浮控制条 (包含设置按钮和启动/停止按钮)
    self.controlBar = [[UIView alloc] initWithFrame:CGRectMake(20, screenSize.height/2, 40, 70)];
    self.controlBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
    self.controlBar.layer.cornerRadius = 20;
    [self.overlayWindow addSubview:self.controlBar];
    
    // 添加拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.controlBar addGestureRecognizer:pan];
    
    // 设置按钮
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.frame = CGRectMake(0, 5, 40, 30);
    [settingsBtn setTitle:@"⚙️" forState:UIControlStateNormal];
    [settingsBtn addTarget:self action:@selector(toggleSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.controlBar addSubview:settingsBtn];
    
    // 启动/停止按钮
    self.toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleBtn.frame = CGRectMake(0, 35, 40, 30);
    [self.toggleBtn setTitle:@"▶️" forState:UIControlStateNormal];
    [self.toggleBtn addTarget:self action:@selector(toggleAutoClick) forControlEvents:UIControlEventTouchUpInside];
    [self.controlBar addSubview:self.toggleBtn];

	[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
	[[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(handleDeviceRotation) 
                                                 name:UIDeviceOrientationDidChangeNotification 
                                               object:nil];
}

#pragma mark - 交互逻辑

- (void)handleDeviceRotation {
    if (!self.overlayWindow) return;
    
    CGSize targetSize = [UIScreen mainScreen].bounds.size;
    
    self.overlayWindow.frame = CGRectMake(0, 0, targetSize.width, targetSize.height);
	self.settingsPanel.center = self.overlayWindow.center;

	// NSLog(@"[AutoClicker] Device rotated. New size: %f x %f", targetSize.width, targetSize.height);
    
    for (int i = 0; i < 10; i++) {
		TapPointModel *model = self.points[i];
        UISlider *xSlider = model.xSlider;
        UISlider *ySlider = model.ySlider;
        
        if (xSlider) xSlider.maximumValue = targetSize.width;
        if (ySlider) ySlider.maximumValue = targetSize.height;
        
        model.x = MIN(model.x, targetSize.width);
        model.y = MIN(model.y, targetSize.height);

        if (xSlider) xSlider.value = model.x;
        if (ySlider) ySlider.value = model.y;

        model.indicatorView.center = CGPointMake(model.x, model.y);
    }
    
    [self clampControlBarToScreen];
}

- (void)clampControlBarToScreen {
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat halfWidth = self.controlBar.bounds.size.width / 2.0;
    CGFloat halfHeight = self.controlBar.bounds.size.height / 2.0;
    CGFloat margin = 5.0;
    
    CGPoint currentCenter = self.controlBar.center;
    currentCenter.x = MAX(halfWidth + margin, MIN(currentCenter.x, screenSize.width - halfWidth - margin));
    currentCenter.y = MAX(halfHeight + 30.0, MIN(currentCenter.y, screenSize.height - halfHeight - 20.0));
    
    [UIView animateWithDuration:0.3 animations:^{
        self.controlBar.center = currentCenter;
    }];
}

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    UIView *panView = recognizer.view;
    CGPoint translation = [recognizer translationInView:self.overlayWindow];
    
    CGPoint newCenter = CGPointMake(panView.center.x + translation.x,
                                    panView.center.y + translation.y);
    
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat halfWidth = panView.bounds.size.width / 2.0;
    CGFloat halfHeight = panView.bounds.size.height / 2.0;
    
    CGFloat margin = 5.0; 
    
    CGFloat minX = halfWidth + margin;
    CGFloat maxX = screenSize.width - halfWidth - margin;
    CGFloat minY = halfHeight + 30.0; 
    CGFloat maxY = screenSize.height - halfHeight - 20.0;
    
    newCenter.x = MAX(minX, MIN(newCenter.x, maxX));
    newCenter.y = MAX(minY, MIN(newCenter.y, maxY));
    
    panView.center = newCenter;
    [recognizer setTranslation:CGPointZero inView:self.overlayWindow];
	[self clampControlBarToScreen];
}

- (void)toggleSettings {
    self.settingsPanel.hidden = !self.settingsPanel.hidden;
}

- (void)intervalChanged:(UISlider *)slider {
    self.clickInterval = slider.value;
	self.intervalLbl.text = [NSString stringWithFormat:@"全局点击间隔: %.2f s", self.clickInterval];
	[self saveSettings];
    if (self.isRunning) {
        // 重启定时器以应用新间隔
        [self stopClicking];
        [self startClicking];
    }
}

- (void)clampIntervalToDuration {
	self.intervalSlider.minimumValue = self.clickDuration + 0.01;
	if (self.clickDuration >= self.clickInterval) {
		self.clickInterval = self.clickDuration + 0.01;
		self.intervalSlider.value = self.clickInterval;
		self.intervalLbl.text = [NSString stringWithFormat:@"全局点击间隔: %.2f s", self.clickInterval];
	}
}

- (void)durationChanged:(UISlider *)slider {
    self.clickDuration = slider.value;
	self.durationLbl.text = [NSString stringWithFormat:@"单次点击时长: %.4f s", self.clickDuration];
	[self clampIntervalToDuration];
	[self saveSettings];
	if (self.isRunning) {
        // 重启定时器以应用新间隔
        [self stopClicking];
        [self startClicking];
    }
}

- (void)switchChanged:(UISwitch *)sender {
    NSInteger index = sender.tag;
    self.points[index].isEnabled = sender.isOn;
    self.points[index].indicatorView.hidden = !sender.isOn; // 同步显示/隐藏指示点

	[self saveSettings];
}

- (void)sliderChanged:(UISlider *)sender {
    NSInteger tag = sender.tag;
    NSInteger index = 0;
    if (tag >= 200) { // Y轴
        index = tag - 200;
        self.points[index].y = sender.value;
    } else if (tag >= 100) { // X轴
        index = tag - 100;
        self.points[index].x = sender.value;
    }
    self.points[index].indicatorView.center = CGPointMake(self.points[index].x, self.points[index].y);

	[self saveSettings];
}

#pragma mark - 连点核心逻辑

- (void)toggleAutoClick {
    if (self.isRunning) {
        [self stopClicking];
        [self.toggleBtn setTitle:@"▶️" forState:UIControlStateNormal];
    } else {
        [self startClicking];
        [self.toggleBtn setTitle:@"⏹" forState:UIControlStateNormal];
    }
}

- (void)startClicking {
    if (self.isRunning) return;
    self.isRunning = YES;
    
    // 使用 GCD 定时器，置于后台线程以免阻塞主线程 UI 渲染
    // dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    // self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    
    uint64_t interval = (uint64_t)(self.clickInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, 0);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
        [weakSelf performClicks];
    });
    
    dispatch_resume(self.timer);
}

- (void)stopClicking {
    if (!self.isRunning) return;
    self.isRunning = NO;
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
}

- (void)performClicks {
    // 遍历所有启用的点，模拟点击
    for (TapPointModel *model in self.points) {
        if (model.isEnabled) {
            // ZSFakeTouch 支持多点，循环快速触发即可
            CGPoint point = CGPointMake(model.x, model.y);
            [ZSFakeTouch beginTouchWithPoint:point];
			if (self.clickDuration > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.clickDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					[ZSFakeTouch endTouchWithPoint:point];
				});
			} else {
				[ZSFakeTouch endTouchWithPoint:point];
			}
        }
    }
}

@end

typedef void (*MSHookMessageEx_t)(Class _class, SEL message, IMP hook, IMP *old);
static MSHookMessageEx_t MSHookMessageEx_p = NULL;

typedef void (*UIWindow_makeKeyAndVisible_t)(id self, SEL _cmd);
static UIWindow_makeKeyAndVisible_t UIWindow_makeKeyAndVisible_p = NULL;

static void makeKeyAndVisible(id self, SEL _cmd) {
	UIWindow_makeKeyAndVisible_p(self, _cmd);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 稍微延迟一下，确保宿主应用主界面渲染完毕
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AutoClickerManager sharedInstance] setupUI];
        });
    });
}

__attribute__((constructor))
static void tweakConstructor() {
    MSHookMessageEx_p = (MSHookMessageEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!MSHookMessageEx_p) {
        return;
    }

	MSHookMessageEx_p(UIWindow.class, @selector(makeKeyAndVisible), (IMP)makeKeyAndVisible, (IMP *)&UIWindow_makeKeyAndVisible_p);
}