#import <Foundation/Foundation.h>
#import "MVRequestGroup.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); failures++; } } while (0)

@interface FakeURLTask : NSObject
@property (atomic) NSUInteger starts;
@property (atomic) NSUInteger cancellations;
- (void)resume;
- (void)cancel;
@end
@implementation FakeURLTask
- (void)resume { self.starts++; }
- (void)cancel { self.cancellations++; }
@end

int main(void) {
    @autoreleasepool {
        MVRequestGroup *group = [MVRequestGroup new];
        FakeURLTask *active = [FakeURLTask new], *finished = [FakeURLTask new], *late = [FakeURLTask new];
        CHECK([group startTask:(id)active]);
        CHECK([group startTask:(id)finished]);
        [group finishTask:(id)finished];
        [group cancel];
        [group cancel];
        CHECK(active.starts == 1 && active.cancellations == 1);
        CHECK(finished.starts == 1 && finished.cancellations == 0);
        CHECK(![group startTask:(id)late] && late.starts == 0);

        // A request racing the stop is either started then cancelled, or never
        // started. No registration can slip past the cancellation barrier.
        for (NSUInteger round = 0; round < 100; round++) {
            MVRequestGroup *racing = [MVRequestGroup new];
            NSMutableArray<FakeURLTask *> *tasks = [NSMutableArray array];
            for (NSUInteger i = 0; i < 40; i++) [tasks addObject:[FakeURLTask new]];
            dispatch_group_t workers = dispatch_group_create();
            dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
            for (FakeURLTask *task in tasks) {
                dispatch_group_async(workers, queue, ^{ [racing startTask:(id)task]; });
            }
            dispatch_group_async(workers, queue, ^{ [racing cancel]; });
            dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);
            for (FakeURLTask *task in tasks) CHECK(task.starts == task.cancellations && task.starts <= 1);
        }
        if (!failures) puts("request cancellation groups: OK");
    }
    return failures ? 1 : 0;
}
