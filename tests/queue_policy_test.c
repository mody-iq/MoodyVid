#include "MVQueuePolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    // Numeric values are on disk and must stay stable across upgrades.
    assert(MVNativeQueued == 0 && MVNativeRunning == 1 && MVNativePaused == 2);
    assert(MVNativeCompleted == 3 && MVNativeFailed == 4 && MVNativeCancelled == 5);
    assert(MVPythonWaiting == 0 && MVPythonActive == 1 && MVPythonCompleted == 2);
    assert(MVPythonFailed == 3 && MVPythonCancelled == 4 && MVPythonPaused == 5);
    for (int state = -1; state <= 6; state++) {
        assert(MVNativeStateAfterRestart(state) == (state == MVNativeRunning ? MVNativeQueued : state));
        assert(MVPythonStateAfterRestart(state) == (state == MVPythonActive ? MVPythonWaiting : state));
        // Calling recovery repeatedly cannot start a second active run.
        int native = MVNativeStateAfterRestart(state);
        int python = MVPythonStateAfterRestart(state);
        assert(MVNativeStateAfterRestart(native) == native);
        assert(MVPythonStateAfterRestart(python) == python);
    }
    // Exercise the complete truth table: restricted downloads start only on a
    // known satisfied Wi-Fi path that is not also reporting cellular.
    for (int restricted = 0; restricted < 2; restricted++)
        for (int known = 0; known < 2; known++)
            for (int satisfied = 0; satisfied < 2; satisfied++)
                for (int wifi = 0; wifi < 2; wifi++)
                    for (int cellular = 0; cellular < 2; cellular++) {
                        int expected = !restricted || (known && satisfied && wifi && !cellular);
                        assert(MVNetworkAllowsNewDownloads(restricted, known, satisfied, wifi, cellular) == expected);
                    }
    puts("queue recovery and admission: OK");
    return 0;
}
