#include "MVHTTPPolicy.h"

#include <stddef.h>
#include <string.h>

static unsigned char MVASCIILower(unsigned char c) {
    return (c >= 'A' && c <= 'Z') ? (unsigned char)(c + ('a' - 'A')) : c;
}

static bool MVASCIIEqual(const char *a, const char *b, size_t length) {
    for (size_t i = 0; i < length; i++) {
        if (MVASCIILower((unsigned char)a[i]) != MVASCIILower((unsigned char)b[i])) return false;
    }
    return true;
}

static bool MVValidHost(const char *host) {
    if (!host || !*host || *host == '.') return false;
    size_t length = strlen(host);
    if (host[length - 1] == '.') return false;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)host[i];
        if (c <= 0x20 || c == 0x7f || c == '/' || c == '\\' || c == '@' || c == '?' || c == '#') return false;
        if (c == '.' && i > 0 && host[i - 1] == '.') return false;
    }
    return true;
}

static bool MVLooksLikeIPAddress(const char *domain) {
    if (strchr(domain, ':')) return true;  // IPv6
    bool onlyDigitsAndDots = true;
    for (const char *p = domain; *p; p++) {
        if ((*p < '0' || *p > '9') && *p != '.') {
            onlyDigitsAndDots = false;
            break;
        }
    }
    return onlyDigitsAndDots;
}

bool MVHTTPCookieDomainMatches(const char *host, const char *cookieDomain) {
    if (!cookieDomain) return false;
    bool permitsSubdomains = cookieDomain[0] == '.';
    const char *domain = permitsSubdomains ? cookieDomain + 1 : cookieDomain;
    if (!MVValidHost(host) || !MVValidHost(domain)) return false;

    size_t hostLength = strlen(host);
    size_t domainLength = strlen(domain);
    if (hostLength == domainLength && MVASCIIEqual(host, domain, domainLength)) return true;

    // A host-only cookie must never be copied to a child or parent host. The
    // leading-dot convention is the only evidence WebKit gives us that this is
    // a domain cookie, so an ambiguous cookie is treated as host-only.
    if (!permitsSubdomains || hostLength <= domainLength || MVLooksLikeIPAddress(domain)) return false;
    // WebKit enforces the public suffix list when accepting website cookies.
    // Also reject a single-label domain such as .com, even if one is injected.
    if (!strchr(domain, '.')) return false;
    size_t suffix = hostLength - domainLength;
    return host[suffix - 1] == '.' && MVASCIIEqual(host + suffix, domain, domainLength);
}

bool MVHTTPCookiePathMatches(const char *requestPath, const char *cookiePath) {
    if (!requestPath || !cookiePath || requestPath[0] != '/' || cookiePath[0] != '/') return false;
    size_t requestLength = strlen(requestPath);
    size_t cookieLength = strlen(cookiePath);
    if (requestLength < cookieLength || strncmp(requestPath, cookiePath, cookieLength) != 0) return false;
    if (requestLength == cookieLength || cookiePath[cookieLength - 1] == '/') return true;
    return requestPath[cookieLength] == '/';
}
