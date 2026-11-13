#include "MVByteRange.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>

int main(void) {
    MVContentRange r;
    assert(MVParseContentRange("bytes 0-99/100", &r));
    assert(r.first == 0 && r.last == 99 && r.total == 100);
    assert(MVContentRangeMatches(&r, 0, 99, 100));
    assert(MVContentRangeMatches(&r, 0, -1, -1));
    assert(!MVContentRangeMatches(&r, 1, 99, 100));
    assert(!MVContentRangeMatches(&r, 0, 98, 100));
    assert(!MVContentRangeMatches(&r, 0, 99, 101));
    assert(!MVContentRangeMatches(NULL, 0, 99, 100));

    assert(MVParseContentRange(" \tByTeS 10-19/*\t", &r));
    assert(r.first == 10 && r.last == 19 && r.total == -1);
    assert(MVContentRangeMatches(&r, 10, 19, -1));
    assert(!MVContentRangeMatches(&r, 10, 19, 20));

    const char *invalid[] = {
        "", "byte 0-1/2", "bytes0-1/2", "bytes */100", "bytes 1-0/2",
        "bytes 0-2/2", "bytes -1-1/2", "bytes +0-1/2", "bytes 0-/2",
        "bytes 0-1/", "bytes 0-1/2garbage", "bytes 0-1/2, bytes 2-3/4",
        "bytes 0-9223372036854775807/*", "bytes 0-1/9223372036854775808",
        "bytes 18446744073709551616-1/*", "bytes 0 -1/2", "bytes 0-1 /2"
    };
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        if (MVParseContentRange(invalid[i], &r)) {
            fprintf(stderr, "accepted invalid Content-Range: %s\n", invalid[i]);
            return 1;
        }
    }
    assert(!MVParseContentRange(NULL, &r));
    assert(!MVParseContentRange("bytes 0-1/2", NULL));
    puts("byte range policy: OK");
    return 0;
}
