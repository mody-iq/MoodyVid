#include "MVThrottle.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    MVThrottleBudget budget;
    MVThrottleInit(&budget, 0, 0);
    /* 200 arrived against 100 of credit; debt persists over later ticks. */
    assert(MVThrottleShouldSuspend(&budget, 200, .25, 400));
    assert(budget.balance == -100);
    assert(!MVThrottleShouldSuspend(&budget, 200, .50, 400));
    assert(budget.balance == 0);
    assert(!MVThrottleShouldSuspend(&budget, 220, .75, 400));
    assert(MVThrottleShouldSuspend(&budget, 500, 1.00, 400));
    assert(budget.balance == -180); /* idle credit was capped */
    assert(MVThrottleShouldSuspend(&budget, 500, 1.25, 400));
    assert(!MVThrottleShouldSuspend(&budget, 500, 1.50, 400));

    assert(MVThrottleShouldSuspend(&budget, 900, 1.75, 400));
    assert(!MVThrottleShouldSuspend(&budget, 900, 2.00, 0));
    assert(budget.balance == 0); /* disabling resumes immediately */
    assert(!MVThrottleShouldSuspend(&budget, 5, 2.25, 400)); /* counter reset */
    assert(MVThrottleShouldSuspend(&budget, 206, 2.50, 400));
    double before = budget.balance;
    assert(MVThrottleShouldSuspend(&budget, 206, NAN, 400));
    assert(MVThrottleShouldSuspend(&budget, 206, 1.0, 400)); /* clock did not go back */
    assert(budget.balance == before);
    assert(!MVThrottleShouldSuspend(NULL, 1, 1, 100));
    puts("direct-transfer throttle policy: OK");
    return 0;
}
