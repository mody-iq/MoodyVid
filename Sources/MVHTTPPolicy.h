#ifndef MV_HTTP_POLICY_H
#define MV_HTTP_POLICY_H

#include <stdbool.h>

/// Match a WebKit cookie domain against a request host. A leading dot on the
/// cookie domain explicitly permits subdomains; without it the match is exact.
/// Both comparisons are ASCII case-insensitive and require a label boundary.
bool MVHTTPCookieDomainMatches(const char *host, const char *cookieDomain);

/// RFC 6265 path matching, on URL-encoded, case-sensitive paths. Both paths
/// must start with '/'; a prefix such as /private must not match /private2.
bool MVHTTPCookiePathMatches(const char *requestPath, const char *cookiePath);

#endif
