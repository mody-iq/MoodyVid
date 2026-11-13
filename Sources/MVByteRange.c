#include "MVByteRange.h"
#include <limits.h>
#include <stddef.h>

static int skip_space(char c) { return c == ' ' || c == '\t'; }

static int parse_number(const char **input, long long *number) {
    const char *p = *input;
    if (*p < '0' || *p > '9') return 0;
    long long n = 0;
    do {
        int digit = *p - '0';
        if (n > (LLONG_MAX - digit) / 10) return 0;
        n = n * 10 + digit;
        p++;
    } while (*p >= '0' && *p <= '9');
    *input = p;
    *number = n;
    return 1;
}

int MVParseContentRange(const char *header, MVContentRange *range) {
    if (!header || !range) return 0;
    const char *p = header;
    while (skip_space(*p)) p++;
    const char *word = "bytes";
    for (; *word; word++, p++) {
        char c = *p;
        if (c >= 'A' && c <= 'Z') c = (char)(c + ('a' - 'A'));
        if (c != *word) return 0;
    }
    if (!skip_space(*p)) return 0;
    while (skip_space(*p)) p++;
    MVContentRange parsed;
    if (!parse_number(&p, &parsed.first) || *p++ != '-' ||
        !parse_number(&p, &parsed.last) || *p++ != '/') return 0;
    if (*p == '*') {
        parsed.total = -1;
        p++;
    } else if (!parse_number(&p, &parsed.total)) return 0;
    while (skip_space(*p)) p++;
    if (*p || parsed.first > parsed.last || parsed.last == LLONG_MAX ||
        (parsed.total >= 0 && parsed.last >= parsed.total)) return 0;
    *range = parsed;
    return 1;
}

int MVContentRangeMatches(const MVContentRange *range, long long expectedFirst,
                          long long expectedLast, long long expectedTotal) {
    if (!range || expectedFirst < 0 || range->first != expectedFirst) return 0;
    if (expectedLast >= 0 && range->last != expectedLast) return 0;
    if (expectedTotal >= 0 && range->total != expectedTotal) return 0;
    return 1;
}
