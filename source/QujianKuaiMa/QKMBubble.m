//
//  QKMBubble.m — 取件快码 Assit / Author: AssitDev
//  SpringBoard 悬浮球：点一下唤起「取件快码」App，可拖动、长按临时隐藏。
//

#import "QKMBubble.h"
#import "QKMConfig.h"

static UIWindow *QKMHostWindow(void) {
    if (@available(iOS 13.0, *)) {
        UIApplication *app = [UIApplication sharedApplication];
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!w.hidden && w.alpha > 0.01) return w;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

@interface QKMBubbleView : UIView
@end

@implementation QKMBubbleView {
    CGPoint _dragStart;
    CGPoint _centerStart;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.28;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        UIView *bg = [[UIView alloc] initWithFrame:self.bounds];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = bg.bounds;
        g.colors = @[(id)[UIColor colorWithRed:0.36 green:0.80 blue:0.70 alpha:1.0].CGColor,
                     (id)[UIColor colorWithRed:0.16 green:0.60 blue:0.54 alpha:1.0].CGColor];
        g.cornerRadius = self.bounds.size.width / 2.0;
        [bg.layer addSublayer:g];
        [self addSubview:bg];

        UILabel *glyph = [[UILabel alloc] initWithFrame:CGRectMake(0, 7, self.bounds.size.width, 26)];
        glyph.text = @"码";
        glyph.textColor = [UIColor whiteColor];
        glyph.font = [UIFont boldSystemFontOfSize:21];
        glyph.textAlignment = NSTextAlignmentCenter;
        [self addSubview:glyph];
        UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(0, 31, self.bounds.size.width, 13)];
        cap.text = @"取件";
        cap.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
        cap.font = [UIFont systemFontOfSize:10];
        cap.textAlignment = NSTextAlignmentCenter;
        [self addSubview:cap];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)]];
    }
    return self;
}

- (void)tapped {
    NSURL *u = [NSURL URLWithString:QKMAppScheme];
    if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

- (void)panned:(UIPanGestureRecognizer *)g {
    UIWindow *w = self.window;
    if (!w) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStart = [g locationInView:w];
        _centerStart = self.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [g locationInView:w];
        self.center = CGPointMake(_centerStart.x + p.x - _dragStart.x,
                                  _centerStart.y + p.y - _dragStart.y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat W = CGRectGetWidth(w.bounds), H = CGRectGetHeight(w.bounds);
        CGFloat r = CGRectGetWidth(self.bounds) / 2.0;
        CGFloat x = (self.center.x < W / 2.0) ? r + 6 : W - r - 6;
        CGFloat y = MIN(MAX(self.center.y, r + 40), H - r - 40);
        [UIView animateWithDuration:0.25 animations:^{ self.center = CGPointMake(x, y); }];
    }
}

@end

@implementation QKMBubble {
    QKMBubbleView *_view;
}

+ (instancetype)shared {
    static QKMBubble *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (void)mount {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = QKMHostWindow();
        if (!w) return;
        if (!self->_view) {
            self->_view = [[QKMBubbleView alloc] initWithFrame:CGRectMake(0, 0, 58, 58)];
            self->_view.center = CGPointMake(CGRectGetWidth(w.bounds) - 38, CGRectGetMidY(w.bounds) - 60);
        }
        if (self->_view.superview != w) [w addSubview:self->_view];
        [w bringSubviewToFront:self->_view];
        self->_view.hidden = ![QKMConfig bubbleEnabled];
    });
}

- (void)setEnabled:(BOOL)on {
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.hidden = !on; });
}

@end
