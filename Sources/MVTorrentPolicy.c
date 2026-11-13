#include "MVTorrentPolicy.h"

bool MVTorrentValidGeometry(int64_t total, int64_t piece_length, int64_t hash_count) {
    if (total < 0 || piece_length <= 0 || piece_length > MV_TORRENT_MAX_PIECE_BYTES ||
        hash_count < 0 || hash_count > MV_TORRENT_MAX_PIECES) return false;
    if (total == 0) return hash_count == 0;
    /* Avoid overflowing total + piece_length - 1. */
    return 1 + (total - 1) / piece_length == hash_count;
}

bool MVTorrentValidMetadataChunk(int64_t total, int64_t index, int64_t length) {
    if (total <= 0 || total > MV_TORRENT_MAX_METADATA_BYTES || index < 0 || length < 0) return false;
    int64_t count = 1 + (total - 1) / MV_TORRENT_METADATA_CHUNK;
    if (index >= count) return false;
    int64_t offset = index * MV_TORRENT_METADATA_CHUNK;
    int64_t remaining = total - offset;
    int64_t expected = remaining < MV_TORRENT_METADATA_CHUNK ? remaining : MV_TORRENT_METADATA_CHUNK;
    return length == expected;
}
