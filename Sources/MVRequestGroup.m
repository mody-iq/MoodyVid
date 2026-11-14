#import "MVRequestGroup.h"

@implementation MVRequestGroup {
    BOOL _cancelled;
    NSMutableSet<NSURLSessionTask *> *_tasks;
}

- (instancetype)init {
    if ((self = [super init])) _tasks = [NSMutableSet set];
    return self;
}

- (BOOL)startTask:(NSURLSessionTask *)task {
    if (!task) return NO;
    @synchronized (self) {
        if (_cancelled) return NO;
        [_tasks addObject:task];
        // Starting while holding the same lock closes the race where cancel
        // could run after registration but before resume.
        [task resume];
        return YES;
    }
}

- (void)finishTask:(NSURLSessionTask *)task {
    if (!task) return;
    @synchronized (self) { [_tasks removeObject:task]; }
}

- (void)cancel {
    NSArray<NSURLSessionTask *> *tasks;
    @synchronized (self) {
        _cancelled = YES;
        tasks = _tasks.allObjects;
        [_tasks removeAllObjects];
    }
    for (NSURLSessionTask *task in tasks) [task cancel];
}
@end
