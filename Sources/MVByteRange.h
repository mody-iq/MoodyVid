#ifndef MV_BYTE_RANGE_H
#define MV_BYTE_RANGE_H

// A validated HTTP Content-Range. total is -1 for an unknown resource size.
typedef struct {
    long long first;
    long long last;
    long long total;
} MVContentRange;

// Accept exactly a single byte range, rejecting malformed, overflowing, or
// internally inconsistent values. Leading/trailing HTTP whitespace is OK.
int MVParseContentRange(const char *header, MVContentRange *range);

// expectedLast or expectedTotal may be -1 when that value is unknown.
int MVContentRangeMatches(const MVContentRange *range, long long expectedFirst,
                          long long expectedLast, long long expectedTotal);

#endif
