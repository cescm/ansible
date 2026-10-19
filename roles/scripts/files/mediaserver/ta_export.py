#!/usr/bin/env python3
"""
ta_export.py — Export TubeArchivist videos as organized symlinks

Connects to the TubeArchivist Elasticsearch index and creates a
directory structure of symlinks organized by playlist (under Playlists/)
or channel (under Channels/). Each symlink targets the original video
file in the TubeArchivist media directory.

Usage:
  ./ta_export.py

Output structure:
  tubearchivist_export/
    Playlists/<playlist_name>/<video_title>.mp4  -> ../../tubearchivist/<id>.mp4
    Channels/<channel_name>/<video_title>.mp4    -> ../../tubearchivist/<id>.mp4

Dependencies: requests (pip install requests)
Requires: Elasticsearch HTTP access on localhost:9200
"""

import os
import re
import requests
from pathlib import Path

TA_MEDIA = Path("/mnt/storage/media/jellyfin/tubearchivist")
EXPORT = Path("/mnt/storage/media/jellyfin/tubearchivist_export")

ES_URL = "http://127.0.0.1:9200"
ES_USER = "elastic"
ES_PASS = "J3sc0b0sA_1976"


def safe(name):
    name = str(name or "unknown")
    name = re.sub(r'[\\/:"*?<>|]+', " - ", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:180] or "unknown"


def es_search(index, body):
    r = requests.get(
        f"{ES_URL}/{index}/_search",
        auth=(ES_USER, ES_PASS),
        json=body,
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["hits"]["hits"]


# Build playlist name lookup from ta_playlist index
playlist_names = {}
for hit in es_search("ta_playlist", {
    "size": 100,
    "_source": ["playlist_id", "playlist_name"],
    "query": {"match_all": {}},
}):
    p = hit["_source"]
    playlist_names[p["playlist_id"]] = p.get("playlist_name", p["playlist_id"])


videos = es_search("ta_video", {
    "size": 10000,
    "_source": [
        "youtube_id",
        "title",
        "channel.channel_name",
        "playlist",
    ],
    "query": {"match_all": {}},
})


created = 0
skipped = 0

for hit in videos:
    v = hit["_source"]

    video_id = v.get("youtube_id") or hit["_id"]
    title = safe(v.get("title", video_id))
    channel = safe(v.get("channel", {}).get("channel_name", "unknown_channel"))

    src_candidates = list(TA_MEDIA.rglob(f"{video_id}.mp4"))

    if not src_candidates:
        skipped += 1
        continue

    src = src_candidates[0]

    playlists = v.get("playlist") or []

    if playlists:
        playlist_id = playlists[0]
        playlist_name = safe(playlist_names.get(playlist_id, playlist_id))
        dst_dir = EXPORT / "Playlists" / playlist_name
    else:
        dst_dir = EXPORT / "Channels" / channel

    dst_dir.mkdir(parents=True, exist_ok=True)

    dst = dst_dir / f"{title}.mp4"

    if dst.exists():
        skipped += 1
        continue

    os.symlink(src, dst)
    created += 1
    print(f"{dst} -> {src}")


print(f"\nCreated symlinks: {created}")
print(f"Skipped: {skipped}")
