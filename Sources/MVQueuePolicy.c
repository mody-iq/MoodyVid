#include "MVQueuePolicy.h"

int MVNativeStateAfterRestart(int state) {
    return state == MVNativeRunning ? MVNativeQueued : state;
}

int MVPythonStateAfterRestart(int state) {
    return state == MVPythonActive ? MVPythonWaiting : state;
}

int MVNetworkAllowsNewDownloads(int wifiOnly, int pathKnown, int satisfied,
                                int usesWifi, int usesCellular) {
    return !wifiOnly || (pathKnown && satisfied && usesWifi && !usesCellular);
}
