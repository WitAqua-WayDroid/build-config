#!/usr/bin/env python
"""Turn the WitAqua WayDroid build targets into Buildkite steps.

Each target line is "<device> <variant> <version> [<type>]", e.g.

    waydroid_x86_64 GAPPS 16.2
    waydroid_x86_64 VANILLA 16.2
    waydroid_tv_x86_64 VANILLA 16.2
"""

from datetime import datetime
import sys
import uuid

import yaml


def main():
    pipeline = {"steps": []}
    today = datetime.today()

    for line in sys.stdin.read().split("\n"):
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        device, variant, version = parts[:3]
        build_type = parts[3] if len(parts) > 3 else "userdebug"

        pipeline['steps'].append({
            'label': '{} {} {}'.format(device, variant, today.strftime("%Y%m%d")),
            'trigger': 'android',
            'build': {
                'env': {
                    'DEVICE': device,
                    'VARIANT': variant,
                    'TYPE': build_type,
                    'VERSION': version,
                    'BUILD_UUID': uuid.uuid4().hex,
                },
                'branch': version,
            },
        })
    print(yaml.dump(pipeline))


if __name__ == '__main__':
    main()
