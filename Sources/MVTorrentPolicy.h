#ifndef MV_TORRENT_POLICY_H
#define MV_TORRENT_POLICY_H

#include <stdbool.h>
#include <stdint.h>

/* Bound metadata expansion and the memory a single piece can require on iOS. */
#define MV_TORRENT_MAX_METADATA_BYTES (16LL * 1024 * 1024)
#define MV_TORRENT_MAX_PIECE_BYTES (16LL * 1024 * 1024)
#define MV_TORRENT_MAX_PIECES 100000LL
#define MV_TORRENT_METADATA_CHUNK 16384LL

bool MVTorrentValidGeometry(int64_t total, int64_t piece_length, int64_t hash_count);
bool MVTorrentValidMetadataChunk(int64_t total, int64_t index, int64_t length);

#endif
