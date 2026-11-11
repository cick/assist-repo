//
//  main.m — 取件快码 Assit / Author: AssitDev
//  v3.0：查件（2.0 面板） / 取件码（1.0 抓码清单） / 安装自检
//

#import <UIKit/UIKit.h>
#import "QKMRootViewController.h"
#import "QKMCodesViewController.h"
#import "QKMDiagnosticsViewController.h"

@interface QKMAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation QKMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor colorWithRed:0.965 green:0.976 blue:0.973 alpha:1.0];

    QKMRootViewController *tab1 = [[QKMRootViewController alloc] init];
    tab1.tabBarItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemSearch tag:0];
    tab1.tabBarItem.title = @"查件";
    UINavigationController *nav1 = [[UINavigationController alloc] initWithRootViewController:tab1];

    QKMCodesViewController *tab2 = [[QKMCodesViewController alloc] init];
    tab2.tabBarItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemBookmarks tag:1];
    tab2.tabBarItem.title = @"取件码";
    UINavigationController *nav2 = [[UINavigationController alloc] initWithRootViewController:tab2];

    QKMDiagnosticsViewController *tab3 = [[QKMDiagnosticsViewController alloc] init];
    tab3.tabBarItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemMore tag:2];
    tab3.tabBarItem.title = @"自检";
    UINavigationController *nav3 = [[UINavigationController alloc] initWithRootViewController:tab3];

    UITabBarController *tabs = [[UITabBarController alloc] init];
    tabs.viewControllers = @[nav1, nav2, nav3];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([QKMAppDelegate class]));
    }
}
