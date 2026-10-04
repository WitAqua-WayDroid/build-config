#!/usr/bin/env python3
"""Add a build to a waydroid OTA channel JSON.

    ota.py <json> <zip> <url> <romtype> <version> <asb> [<build timestamp>]

waydroid reads <system channel>/lineage/waydroid_<arch>/<romtype>.json and
<vendor channel>/waydroid_<arch>/MAINLINE.json, newest build first, in the
same format WayDroid-ATV's channels use.
"""

import hashlib
import json
import os
import sys
import time


def main():
    path, zip_path, url, romtype, version, asb = sys.argv[1:7]
    # waydroid updates when the newest entry's datetime is past the installed one's
    built = int(sys.argv[7]) if len(sys.argv) > 7 else int(time.time())

    sha256 = hashlib.sha256()
    with open(zip_path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            sha256.update(chunk)

    entry = {
        'datetime': built,
        'filename': os.path.basename(zip_path),
        'id': sha256.hexdigest(),
        'romtype': romtype,
        'asb': asb,
        'size': os.path.getsize(zip_path),
        'url': url,
        'version': version,
    }

    if os.path.exists(path):
        with open(path) as f:
            channel = json.load(f)
    else:
        channel = {'response': []}
    builds = [b for b in channel['response'] if b['filename'] != entry['filename']]
    channel['response'] = [entry] + builds

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(channel, f, indent=2)
        f.write('\n')


if __name__ == '__main__':
    main()
