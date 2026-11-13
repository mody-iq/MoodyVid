#ifndef MV_THROTTLE_H
#define MV_THROTTLE_H

#include <stdbool.h>

/* Approximate per-transfer budget, sampled on a monotonic clock. The caller
 * suspends/resumes its network tasks when this policy's return value changes.
 * Previously delivered bytes carry a debt; buffered/short transfers can still
 * overshoot because this policy cannot control bytes already in flight. */
typedef struct {
    double balance;
    double last_time;
    long long last_bytes;
} MVThrottleBudget;

void MVThrottleInit(MVThrottleBudget *budget, long long bytes, double now);
bool MVThrottleShouldSuspend(MVThrottleBudget *budget, long long bytes,
                             double now, long long bytes_per_second);

#endif
