#include "../Sources/MVTorrentPolicy.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    assert(MVTorrentValidGeometry(1, 1, 1));
    assert(MVTorrentValidGeometry(32769, 16384, 3));
    assert(!MVTorrentValidGeometry(32769, 16384, 2));
    assert(!MVTorrentValidGeometry(0, 1, 1));
    assert(MVTorrentValidGeometry(0, 1, 0));
    assert(!MVTorrentValidGeometry(1, 0, 1));
    assert(!MVTorrentValidGeometry(INT64_MAX, 1, 1));
    assert(!MVTorrentValidGeometry(1, MV_TORRENT_MAX_PIECE_BYTES + 1, 1));
    assert(!MVTorrentValidGeometry(MV_TORRENT_MAX_PIECES + 1, 1, MV_TORRENT_MAX_PIECES + 1));
    assert(MVTorrentValidMetadataChunk(16385, 0, 16384));
    assert(MVTorrentValidMetadataChunk(16385, 1, 1));
    assert(!MVTorrentValidMetadataChunk(16385, 1, 16384));
    assert(!MVTorrentValidMetadataChunk(16385, 2, 0));
    assert(!MVTorrentValidMetadataChunk(MV_TORRENT_MAX_METADATA_BYTES + 1, 0, 16384));
    assert(!MVTorrentValidMetadataChunk(INT64_MAX, INT64_MAX, 1));
    puts("torrent policy tests passed");
    return 0;
}
