#import <UIKit/UIKit.h>
#include <dlfcn.h>
#import "ZSFakeTouch/ZSFakeTouchDome/ZSFakeTouch/ZSFakeTouch.h"

// --- 预设 10 个点的数据模型 ---
@interface TapPointModel : NSObject
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) CGFloat x;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, strong) UIView *indicatorView; // 屏幕上的指示红点
@end

@implementation TapPointModel
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
@end

@interface AutoClickerManager : NSObject
@property (nonatomic, strong) FloatingOverlayWindow *overlayWindow;
@property (nonatomic, strong) UIView *controlBar;       // 悬浮控制栏
@property (nonatomic, strong) UIView *settingsPanel;    // 设置面板
@property (nonatomic, strong) UIButton *toggleBtn;      // 启动/停止按钮
@property (nonatomic, strong) UILabel *intervalLbl;
@property (nonatomic, strong) NSMutableArray<TapPointModel *> *points;
@property (nonatomic, assign) CGFloat clickInterval;    // 全局点击间隔 (秒)
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

- (instancetype)init {
    self = [super init];
    if (self) {
        _clickInterval = 0.1; // 默认 0.1 秒
        _points = [NSMutableArray array];
        for (int i = 0; i < 10; i++) {
            TapPointModel *model = [[TapPointModel alloc] init];
            model.isEnabled = NO;
            model.x = [UIScreen mainScreen].bounds.size.width / 2;
            model.y = [UIScreen mainScreen].bounds.size.height / 2;
            [_points addObject:model];
        }
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
        indicator.hidden = YES;
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
    
    // 3. 设置面板 (隐藏状态)
    self.settingsPanel = [[UIView alloc] initWithFrame:CGRectMake(20, 100, screenSize.width - 40, screenSize.height - 200)];
    self.settingsPanel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.6];
    self.settingsPanel.layer.cornerRadius = 15;
    self.settingsPanel.hidden = YES;
    [self.overlayWindow addSubview:self.settingsPanel];
    
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.settingsPanel.bounds];
    [self.settingsPanel addSubview:scrollView];
    
    CGFloat currentY = 20;
    
    // 全局间隔设置
    self.intervalLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 200, 30)];
    self.intervalLbl.text = [NSString stringWithFormat:@"全局点击间隔: %.2f s", self.clickInterval];
    self.intervalLbl.textColor = [UIColor whiteColor];
    [scrollView addSubview:self.intervalLbl];
    
    UISlider *intervalSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, currentY + 30, scrollView.frame.size.width - 40, 30)];
    intervalSlider.minimumValue = 0.05;
    intervalSlider.maximumValue = 2.0;
    intervalSlider.value = self.clickInterval;
    [intervalSlider addTarget:self action:@selector(intervalChanged:) forControlEvents:UIControlEventValueChanged];
    [scrollView addSubview:intervalSlider];
    
    currentY += 80;
    
    // 10个点的设置生成
    for (int i = 0; i < 10; i++) {
        UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 100, 30)];
        titleLbl.text = [NSString stringWithFormat:@"点位 %d", i+1];
        titleLbl.textColor = [UIColor whiteColor];
        titleLbl.font = [UIFont boldSystemFontOfSize:16];
        [scrollView addSubview:titleLbl];
        
        UISwitch *enableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(120, currentY, 50, 30)];
        enableSwitch.tag = i;
        [enableSwitch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:enableSwitch];
        
        currentY += 40;
        
        // X 轴滑块
        UISlider *xSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, currentY, scrollView.frame.size.width - 40, 30)];
        xSlider.minimumValue = 0;
        xSlider.maximumValue = screenSize.width;
        xSlider.value = self.points[i].x;
        xSlider.tag = 100 + i; // 加 100 区分 X
        [xSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:xSlider];
        
        currentY += 40;
        
        // Y 轴滑块
        UISlider *ySlider = [[UISlider alloc] initWithFrame:CGRectMake(20, currentY, scrollView.frame.size.width - 40, 30)];
        ySlider.minimumValue = 0;
        ySlider.maximumValue = screenSize.height;
        ySlider.value = self.points[i].y;
        ySlider.tag = 200 + i; // 加 200 区分 Y
        [ySlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:ySlider];
        
        currentY += 40;
        
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, currentY, scrollView.frame.size.width - 20, 1)];
        line.backgroundColor = [UIColor darkGrayColor];
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
}

#pragma mark - 交互逻辑

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:self.overlayWindow];
    CGPoint newCenter = CGPointMake(recognizer.view.center.x + translation.x,
                                    recognizer.view.center.y + translation.y);
    recognizer.view.center = newCenter;
    [recognizer setTranslation:CGPointZero inView:self.overlayWindow];
}

- (void)toggleSettings {
    self.settingsPanel.hidden = !self.settingsPanel.hidden;
}

- (void)intervalChanged:(UISlider *)slider {
    self.clickInterval = slider.value;
	self.intervalLbl.text = [NSString stringWithFormat:@"全局点击间隔: %.2f s", self.clickInterval];
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [ZSFakeTouch endTouchWithPoint:point];
            });
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