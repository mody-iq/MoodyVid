#include "MVThrottle.h"
#include <math.h>

/* At most one timer interval of idle credit may be spent as a burst. */
static const double kBurstSeconds = 0.25;

void MVThrottleInit(MVThrottleBudget *budget, long long bytes, double now) {
    if (!budget) return;
    budget->balance = 0;
    budget->last_bytes = bytes > 0 ? bytes : 0;
    budget->last_time = isfinite(now) ? now : 0;
}

bool MVThrottleShouldSuspend(MVThrottleBudget *budget, long long bytes,
                             double now, long long bytes_per_second) {
    if (!budget) return false;
    long long current = bytes > 0 ? bytes : 0;
    long long delta = current >= budget->last_bytes ? current - budget->last_bytes : 0;
    budget->last_bytes = current;
    if (!isfinite(now) || now < budget->last_time) now = budget->last_time;
    double elapsed = now - budget->last_time;
    budget->last_time = now;
    if (bytes_per_second <= 0) {
        budget->balance = 0;
        return false;
    }
    double limit = (double)bytes_per_second;
    budget->balance = fmin(limit * kBurstSeconds, budget->balance + limit * elapsed) - (double)delta;
    return budget->balance < 0;
}
