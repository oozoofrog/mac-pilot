#ifdef PRODUCT_ENTRY_GUARD
#import <Foundation/Foundation.h>
#else
#import <UIKit/UIKit.h>
#endif
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    const char *token = getenv("MAC_CU_FIXTURE_SESSION");
    if (argc != 3 || strcmp(argv[1], "--fixture-session") || !token || strcmp(argv[2], token)
        || getenv("MAC_CU_FIXTURE_CHILD")) return 64;
    setenv("MAC_CU_FIXTURE_CHILD", "1", 1);
    #ifdef PRODUCT_ENTRY_GUARD
    return 0;
    #else
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"ResidentProductDelegate"); }
    #endif
}
