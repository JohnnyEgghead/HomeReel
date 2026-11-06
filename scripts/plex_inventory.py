#!/usr/bin/env python3
"""Read-only inventory of Movies and TV Shows on a Plex server.

Reads the token from ~/.config/homereel/plex-token (never from the repo).
Writes the raw per-file table to ~/.config/homereel/inventory.json (private)
and prints count-only summaries (safe to commit).
"""
import collections
import json
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

if len(sys.argv) < 2:
    sys.exit("Usage: plex_inventory.py http://<server address>:32400")
BASE = sys.argv[1]
CFG = os.path.expanduser("~/.config/homereel")
with open(f"{CFG}/plex-token") as f:
    TOKEN = f.read().strip()

def get(path):
    sep = "&" if "?" in path else "?"
    req = urllib.request.Request(f"{BASE}{path}{sep}X-Plex-Token={TOKEN}",
                                 headers={"Accept": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)["MediaContainer"]
        except Exception:
            if attempt == 4:
                raise
            time.sleep(2 * (attempt + 1))

def listing(section, typ):
    out, start = [], 0
    while True:
        c = get(f"/library/sections/{section}/all?type={typ}&X-Plex-Container-Start={start}&X-Plex-Container-Size=500")
        out += c.get("Metadata", [])
        start += 500
        if start >= c["totalSize"]:
            return out

def detail(item):
    m = get(f"/library/metadata/{item['ratingKey']}")["Metadata"][0]
    rows = []
    for media in m.get("Media", []):
        for part in media.get("Part", []):
            v = [s for s in part.get("Stream", []) if s["streamType"] == 1]
            a = [s for s in part.get("Stream", []) if s["streamType"] == 2]
            t = [s for s in part.get("Stream", []) if s["streamType"] == 3]
            v0 = v[0] if v else {}
            rows.append({
                "kind": item["type"], "ratingKey": item["ratingKey"], "title": item.get("title"),
                "container": media.get("container"), "video": v0.get("codec"),
                "vprofile": v0.get("profile"), "bitdepth": v0.get("bitDepth"),
                "res": media.get("videoResolution"),
                "dv": v0.get("DOVIPresent"), "dv_profile": v0.get("DOVIProfile"),
                "dv_bl": v0.get("DOVIBLPresent"), "dv_el": v0.get("DOVIELPresent"),
                "dv_compat": v0.get("DOVIBLCompatID"),
                "color_trc": v0.get("colorTrc"), "color_space": v0.get("colorSpace"),
                "audio": sorted({(s.get("codec"), s.get("channels"), s.get("audioChannelLayout")) for s in a}, key=str),
                "subs": sorted({(s.get("codec"), "ext" if s.get("key") else "emb") for s in t}, key=str),
                "size": part.get("size"),
            })
    return rows

def library_keys():
    """The ids of every Movie and TV library. They differ from server to server."""
    sections = get("/library/sections").get("Directory", [])
    def keys(kind):
        return [s["key"] for s in sections if s.get("type") == kind]
    return keys("movie"), keys("show")

def main():
    movies, shows = library_keys()
    items = [i for k in movies for i in listing(k, 1)] + [i for k in shows for i in listing(k, 4)]
    print(f"items: {len(items)}", file=sys.stderr)
    with ThreadPoolExecutor(3) as ex:
        rows = [r for rs in ex.map(detail, items) for r in rs]
    with open(f"{CFG}/inventory.json", "w") as f:
        json.dump(rows, f)
    for kind in ("movie", "episode"):
        R = [r for r in rows if r["kind"] == kind]
        print(f"\n## {kind}s: {len(R)} files")
        def tally(name, key):
            c = collections.Counter(key(r) for r in R)
            print(f"\n{name}")
            for k, n in c.most_common():
                print(f"  {n:6d}  {k}")
        tally("container", lambda r: r["container"])
        tally("video codec / profile / bit depth", lambda r: f'{r["video"]} {r["vprofile"]} {r["bitdepth"]}bit')
        tally("resolution", lambda r: r["res"])
        tally("HDR / Dolby Vision", lambda r: ("DV P%s (BL=%s EL=%s compat=%s)" % (r["dv_profile"], r["dv_bl"], r["dv_el"], r["dv_compat"])) if r["dv"] else ("HDR10/PQ" if r["color_trc"] == "smpte2084" else ("HLG" if r["color_trc"] == "arib-std-b67" else "SDR")))
        c = collections.Counter()
        c2 = collections.Counter()
        for r in R:
            for a in {x[0] for x in r["audio"]}:
                c[a] += 1
            for s in r["subs"]:
                c2[s] += 1
        print("\naudio codecs (files containing)")
        for k, n in c.most_common():
            print(f"  {n:6d}  {k}")
        print("\nsubtitle formats (files containing)")
        for k, n in c2.most_common():
            print(f"  {n:6d}  {k}")

if __name__ == "__main__":
    main()
