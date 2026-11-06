#import "MVPython.h"
#import <UIKit/UIKit.h>
#import <JavaScriptCore/JavaScriptCore.h>
#include <Python/Python.h>

// ---------------------------------------------------------------------------
// The `mvnative` module: the one thing Python cannot do on iOS is run
// JavaScript, and yt-dlp needs that to solve YouTube's player challenges.
// Apple's JavaScriptCore is already on the device, so we expose it here as a
// plain function. Registering the module before Py_Initialize makes it
// importable as `import mvnative`.
// ---------------------------------------------------------------------------

static PyObject *mv_run_js(PyObject *self, PyObject *args) {
    const char *code = NULL;
    Py_ssize_t len = 0;
    if (!PyArg_ParseTuple(args, "s#", &code, &len)) return NULL;
    NSString *src = [[NSString alloc] initWithBytes:code length:(NSUInteger)len encoding:NSUTF8StringEncoding];
    if (!src) return Py_BuildValue("(Os)", Py_False, "the script was not valid UTF-8");

    __block NSString *output = @"";
    __block NSString *error = nil;
    // Long scripts block, and the interpreter must stay responsive: drop the GIL.
    Py_BEGIN_ALLOW_THREADS
    @autoreleasepool {
        JSContext *ctx = [JSContext new];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        ctx.exceptionHandler = ^(JSContext *c, JSValue *exception) {
            if (!error) error = [exception toString] ?: @"unknown JavaScript error";
        };
        // yt-dlp's solver prints its answer with console.log, so collect those.
        JSValue *console = [JSValue valueWithNewObjectInContext:ctx];
        console[@"log"] = ^{
            NSMutableArray *parts = [NSMutableArray array];
            for (JSValue *v in [JSContext currentArguments]) [parts addObject:[v toString] ?: @""];
            [lines addObject:[parts componentsJoinedByString:@" "]];
        };
        void (^ignore)(void) = ^{};
        console[@"warn"] = ignore;
        console[@"error"] = ignore;
        console[@"info"] = ignore;
        console[@"debug"] = ignore;
        ctx[@"console"] = console;
        [ctx evaluateScript:src];
        output = [lines componentsJoinedByString:@"\n"];
    }
    Py_END_ALLOW_THREADS

    if (error) return Py_BuildValue("(Os)", Py_False, error.UTF8String);
    return Py_BuildValue("(Os)", Py_True, output.UTF8String);
}

static PyMethodDef MVMethods[] = {
    {"run_js", mv_run_js, METH_VARARGS, "Runs JavaScript in JavaScriptCore; returns (ok, output or error)."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef MVNativeModule = {
    PyModuleDef_HEAD_INIT, "mvnative", "Native helpers for the MoodyVid engine.", -1, MVMethods,
};

static PyObject *PyInit_mvnative(void) { return PyModule_Create(&MVNativeModule); }

@interface MVPython ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_group_t ready;
@property (nonatomic, nullable) NSString *startError;
@property (nonatomic) BOOL started;
@end

@implementation MVPython

+ (instancetype)shared {
    static MVPython *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [MVPython new];
        instance.queue = dispatch_queue_create("com.mody.moodyvid.python", DISPATCH_QUEUE_SERIAL);
        instance.ready = dispatch_group_create();
    });
    return instance;
}

// The error type, its message and where it happened, so a failed start can be diagnosed.
static NSString *pyErrorString(void) {
    if (!PyErr_Occurred()) return @"Unknown engine error (no details).";
    PyObject *exc = PyErr_GetRaisedException();
    NSString *msg = nil;
    PyObject *tb = PyImport_ImportModule("traceback");
    PyObject *lines = (tb && exc) ? PyObject_CallMethod(tb, "format_exception", "O", exc) : NULL;
    if (lines) {
        PyObject *empty = PyUnicode_FromString("");
        PyObject *joined = empty ? PyUnicode_Join(empty, lines) : NULL;
        if (joined) msg = [NSString stringWithUTF8String:PyUnicode_AsUTF8(joined) ?: ""];
        Py_XDECREF(joined);
        Py_XDECREF(empty);
    }
    if (!msg.length && exc) {
        PyObject *name = PyObject_GetAttrString((PyObject *)Py_TYPE(exc), "__name__");
        PyObject *s = PyObject_Str(exc);
        msg = [NSString stringWithFormat:@"%s: %s",
               name ? PyUnicode_AsUTF8(name) : "Error", s ? PyUnicode_AsUTF8(s) : ""];
        Py_XDECREF(name);
        Py_XDECREF(s);
    }
    PyErr_Clear();
    Py_XDECREF(lines);
    Py_XDECREF(tb);
    Py_XDECREF(exc);
    msg = [msg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return msg.length ? msg : @"Unknown engine error (no details).";
}

- (void)start {
    if (self.started) return;
    self.started = YES;
    dispatch_group_enter(self.ready);
    dispatch_async(self.queue, ^{
        [self startOnQueue];
        dispatch_group_leave(self.ready);
    });
}

- (void)startOnQueue {
    NSString *res = NSBundle.mainBundle.resourcePath;
    NSString *home = [res stringByAppendingPathComponent:@"python"];
    NSString *appDir = [res stringByAppendingPathComponent:@"app"];
    NSString *pkgDir = [res stringByAppendingPathComponent:@"app_packages"];

    setenv("NO_COLOR", "1", 1);
    setenv("PYTHON_COLORS", "0", 1);
    setenv("PYTHONIOENCODING", "utf-8", 1);
    setenv("TMPDIR", NSTemporaryDirectory().fileSystemRepresentation, 1);
    // Where downloads are kept: Documents, so they survive and show up in the
    // Files app (Info.plist enables file sharing). TMPDIR is purged by iOS.
    setenv("MV_DOCUMENTS",
           NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject.fileSystemRepresentation,
           1);
    // Used by mvboot when Python can't read the iOS version itself (see _ctypes_guard).
    setenv("MV_IOS_NAME", UIDevice.currentDevice.systemName.UTF8String ?: "iOS", 1);
    setenv("MV_IOS_VERSION", UIDevice.currentDevice.systemVersion.UTF8String ?: "", 1);
    setenv("MV_IOS_MODEL", UIDevice.currentDevice.model.UTF8String ?: "iPhone", 1);

    // Must happen before the interpreter starts, or the import would fail.
    if (PyImport_AppendInittab("mvnative", &PyInit_mvnative) < 0) {
        self.startError = @"Couldn't register the JavaScript helper.";
        return;
    }

    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    PyStatus st = Py_PreInitialize(&pre);
    if (PyStatus_Exception(st)) {
        self.startError = [NSString stringWithFormat:@"Couldn't start the engine (pre-init): %s",
                           st.err_msg ?: "unknown"];
        return;
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.buffered_stdio = 0;
    config.write_bytecode = 1;
    wchar_t *whome = Py_DecodeLocale(home.fileSystemRepresentation, NULL);
    st = PyConfig_SetString(&config, &config.home, whome);
    PyMem_RawFree(whome);
    // Python finds its compiled modules (Frameworks/*.framework) next to the executable.
    wchar_t *wexe = Py_DecodeLocale(NSBundle.mainBundle.executablePath.fileSystemRepresentation, NULL);
    if (!PyStatus_Exception(st)) st = PyConfig_SetString(&config, &config.executable, wexe);
    if (!PyStatus_Exception(st)) st = PyConfig_SetString(&config, &config.program_name, wexe);
    PyMem_RawFree(wexe);
    if (!PyStatus_Exception(st)) st = PyConfig_Read(&config);
    if (!PyStatus_Exception(st)) st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(st)) {
        self.startError = [NSString stringWithFormat:@"Couldn't start the engine: %s",
                           st.err_msg ?: "unknown"];
        return;
    }

    PyObject *sysPath = PySys_GetObject("path");  // borrowed reference
    for (NSString *p in @[pkgDir, appDir]) {
        PyObject *s = PyUnicode_FromString(p.UTF8String);
        PyList_Insert(sysPath, 0, s);
        Py_DECREF(s);
    }

    PyObject *boot = PyImport_ImportModule("mvboot");
    if (!boot) self.startError = [@"Couldn't load the engine boot module: " stringByAppendingString:pyErrorString()];
    Py_XDECREF(boot);
    PyErr_Clear();

    // Release the GIL; every later call takes it with PyGILState_Ensure.
    PyEval_SaveThread();
}

- (void)call:(NSString *)module
    function:(NSString *)function
        args:(NSArray<NSString *> *)args
  completion:(void (^)(NSDictionary *_Nullable, NSString *_Nullable))completion {
    [self start];
    dispatch_group_notify(self.ready, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (self.startError) {
            NSString *e = self.startError;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, e); });
            return;
        }
        NSString *json = nil, *err = nil;
        PyGILState_STATE g = PyGILState_Ensure();
        PyObject *mod = PyImport_ImportModule(module.UTF8String);
        PyObject *fn = mod ? PyObject_GetAttrString(mod, function.UTF8String) : NULL;
        PyObject *tuple = NULL;
        if (mod) {
            tuple = PyTuple_New((Py_ssize_t)args.count);
            for (NSUInteger i = 0; tuple && i < args.count; i++) {
                // PyUnicode_FromString returns NULL for invalid UTF-8; a NULL slot
                // in the tuple would crash when Python reads the arguments.
                PyObject *item = PyUnicode_FromString(args[i].UTF8String ?: "");
                if (!item) { Py_CLEAR(tuple); break; }
                PyTuple_SetItem(tuple, (Py_ssize_t)i, item);  // steals the reference
            }
        }
        PyObject *r = (fn && tuple) ? PyObject_CallObject(fn, tuple) : NULL;
        if (r && PyUnicode_Check(r)) json = [NSString stringWithUTF8String:PyUnicode_AsUTF8(r) ?: "{}"];
        else err = pyErrorString();
        PyErr_Clear();
        Py_XDECREF(r);
        Py_XDECREF(tuple);
        Py_XDECREF(fn);
        Py_XDECREF(mod);
        PyGILState_Release(g);

        NSDictionary *result = nil;
        if (json) {
            id obj = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                     options:0 error:nil];
            if ([obj isKindOfClass:NSDictionary.class]) result = obj;
            else err = @"The engine returned something unexpected.";
        }
        if (result[@"error"]) { err = result[@"error"]; result = nil; }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, err); });
    });
}

@end
