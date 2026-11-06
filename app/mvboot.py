"""MoodyVid engine bootstrap and self-test (runs inside the embedded Python)."""
import json
import os
import sys


def _ctypes_guard():
    """Some jailbroken devices can't load Python's ctypes: importing it raises and would
    take the whole engine down. Python only needs it to read the iOS version, so we answer
    that ourselves and make ctypes a normal "not available" for everything else."""
    if sys.platform != 'ios':
        return
    try:
        import _ctypes  # noqa: F401
        return
    except BaseException:
        pass
    import types
    sys.modules['ctypes'] = None
    sys.modules['_ctypes'] = None
    m = types.ModuleType('_ios_support')
    m.get_platform_ios = lambda: (os.environ.get('MV_IOS_NAME') or 'iOS',
                                  os.environ.get('MV_IOS_VERSION') or '',
                                  os.environ.get('MV_IOS_MODEL') or 'iPhone',
                                  False)
    sys.modules['_ios_support'] = m


_ctypes_guard()


def _use_bundled_certificates():
    """iOS has no system CA store, so point OpenSSL at the certifi bundle we ship."""
    try:
        import certifi
    except BaseException:
        return False
    if os.path.exists(certifi.where()):
        os.environ.setdefault('SSL_CERT_FILE', certifi.where())
        return True
    return False


_use_bundled_certificates()


def _err(e):
    return f'{type(e).__name__}: {e}'


def info():
    """Self-test. Returns a JSON string describing what works inside the engine."""
    out = {'python': sys.version.split()[0], 'platform': sys.platform}
    try:
        import ssl
        out['ssl'] = ssl.OPENSSL_VERSION
    except BaseException as e:
        out['ssl_error'] = _err(e)
    out['certifi'] = _use_bundled_certificates()
    if not out['certifi']:
        out['certifi_error'] = 'the CA bundle is missing'
    try:
        from yt_dlp.version import __version__ as ytdlp_version
        out['yt_dlp'] = ytdlp_version
    except BaseException as e:
        out['yt_dlp_error'] = _err(e)
    try:
        import yt_dlp_ejs  # noqa: F401
        out['ejs'] = True
    except BaseException as e:
        out['ejs_error'] = _err(e)
    try:
        from downloader import _HAS_JAVASCRIPTCORE
        out['javascriptcore'] = _HAS_JAVASCRIPTCORE
    except BaseException as e:
        out['javascriptcore_error'] = _err(e)
    return json.dumps(out)
