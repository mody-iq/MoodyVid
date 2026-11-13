#include "MVHTTPPolicy.h"

#include <stdio.h>

static int failures = 0;

#define CHECK(condition, description) do { \
    if (!(condition)) { fprintf(stderr, "FAIL: %s\n", (description)); failures++; } \
} while (0)

int main(void) {
    CHECK(MVHTTPCookieDomainMatches("example.com", "example.com"), "exact host cookie");
    CHECK(MVHTTPCookieDomainMatches("EXAMPLE.COM", "example.com"), "host is case insensitive");
    CHECK(MVHTTPCookieDomainMatches("example.com", ".example.com"), "domain cookie on its own domain");
    CHECK(MVHTTPCookieDomainMatches("media.example.com", ".Example.COM"), "explicit domain cookie on subdomain");
    CHECK(MVHTTPCookieDomainMatches("a.b.example.com", ".example.com"), "nested subdomain");
    CHECK(!MVHTTPCookieDomainMatches("media.example.com", "example.com"), "host-only cookie not sent to subdomain");
    CHECK(!MVHTTPCookieDomainMatches("evil-example.com", "example.com"), "no suffix without a label boundary");
    CHECK(!MVHTTPCookieDomainMatches("evil-example.com", ".example.com"), "domain cookie cannot match lookalike host");
    CHECK(!MVHTTPCookieDomainMatches("example.com.evil.test", ".example.com"), "domain cannot match a prefix");
    CHECK(!MVHTTPCookieDomainMatches("example.com", "login.example.com"), "child cookie not sent to parent");
    CHECK(!MVHTTPCookieDomainMatches("cdn.example.com", ".login.example.com"), "sibling domain not matched");
    CHECK(!MVHTTPCookieDomainMatches("evil.com", ".com"), "single-label domain cannot match all hosts");
    CHECK(!MVHTTPCookieDomainMatches("foo.127.0.0.1", ".127.0.0.1"), "IP address cannot match subdomains");
    CHECK(!MVHTTPCookieDomainMatches("x..example.com", ".example.com"), "malformed host rejected");
    CHECK(!MVHTTPCookieDomainMatches("example.com.", ".example.com"), "trailing-dot host rejected conservatively");
    CHECK(!MVHTTPCookieDomainMatches("example.com", "..example.com"), "malformed cookie domain rejected");
    CHECK(!MVHTTPCookieDomainMatches("example.com", NULL), "missing cookie domain rejected");
    CHECK(!MVHTTPCookieDomainMatches(NULL, "example.com"), "missing host rejected");

    CHECK(MVHTTPCookiePathMatches("/", "/"), "root path");
    CHECK(MVHTTPCookiePathMatches("/private", "/private"), "exact path");
    CHECK(MVHTTPCookiePathMatches("/private/video", "/private"), "path on segment boundary");
    CHECK(MVHTTPCookiePathMatches("/private/video", "/private/"), "cookie path ending in slash");
    CHECK(!MVHTTPCookiePathMatches("/private2", "/private"), "path prefix without boundary rejected");
    CHECK(!MVHTTPCookiePathMatches("/Private/video", "/private"), "path remains case sensitive");
    CHECK(!MVHTTPCookiePathMatches("/private%2Fvideo", "/private"), "encoded slash is not a path boundary");
    CHECK(!MVHTTPCookiePathMatches("/", "/private"), "parent path rejected");
    CHECK(!MVHTTPCookiePathMatches("relative", "/"), "relative request path rejected");
    CHECK(!MVHTTPCookiePathMatches("/private", ""), "empty cookie path rejected");
    CHECK(!MVHTTPCookiePathMatches(NULL, "/"), "missing request path rejected");

    if (failures) fprintf(stderr, "%d HTTP POLICY FAILURE(S)\n", failures);
    else puts("ALL HTTP POLICY TESTS PASSED");
    return failures ? 1 : 0;
}
