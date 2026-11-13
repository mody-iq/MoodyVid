#ifndef MV_QUEUE_POLICY_H
#define MV_QUEUE_POLICY_H

// Persisted state values shared by both Objective-C stores and the portable
// recovery tests. Never renumber these: they are written to users' JSON files.
enum {
    MVNativeQueued = 0, MVNativeRunning = 1, MVNativePaused = 2,
    MVNativeCompleted = 3, MVNativeFailed = 4, MVNativeCancelled = 5
};
enum {
    MVPythonWaiting = 0, MVPythonActive = 1, MVPythonCompleted = 2,
    MVPythonFailed = 3, MVPythonCancelled = 4, MVPythonPaused = 5
};

// Process death interrupts work in flight; it does not undo an explicit pause,
// cancellation, failure, or completion. Unknown values are left unchanged.
int MVNativeStateAfterRestart(int state);
int MVPythonStateAfterRestart(int state);

// This is an admission rule, NOT a per-socket cellular firewall. An unknown,
// unsatisfied, or ambiguous path cannot start new work when the rule is on.
int MVNetworkAllowsNewDownloads(int wifiOnly, int pathKnown, int satisfied,
                                int usesWifi, int usesCellular);

#endif
