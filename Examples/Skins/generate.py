#!/usr/bin/env python3
"""Rebuild original geometric artwork, v1 author JSON and page-motion XML (stdlib only)."""
import json
import math
from pathlib import Path
import struct
import zlib
import uuid

ROOT = Path(__file__).resolve().parent
STATES = ('normal', 'hover', 'pressed', 'selected', 'focus', 'disabled', 'loading', 'error')
SLOTS = ('workCard', 'list', 'search', 'navigation', 'primaryAction', 'tabs', 'progress', 'background', 'icon', 'placeholder', 'decoration', 'panel', 'header', 'row', 'result', 'task', 'workRow', 'linkRow', 'emptyState')
COMPONENTS = ('discovery.schedule', 'discovery.updates', 'discovery.recommendations', 'search.results', 'downloads.tasks', 'favorites.works', 'favorites.links')
LICENSE = 'CC0-1.0; original geometric artwork and example JSON dedicated to the public domain. https://creativecommons.org/publicdomain/zero/1.0/'

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

def png(path, role, state=0, dark=False):
    w, h = (320, 180) if role in ('background', 'preview') else (96, 96)
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            if role in ('background', 'preview'):
                base = (24, 35, 49) if dark else (231, 241, 249)
                band = 8 if ((x + y) // 32) % 2 else 0
                c = tuple(min(255, v + band) for v in base) + (255,)
            else:
                dx, dy = x - w / 2, y - h / 2
                ring = 22 < math.hypot(dx, dy) < 30
                diamond = abs(dx) + abs(dy) < 22
                mountain = 20 < y < 76 and abs(dx) < (y - 20) * .65
                stroke = ring if role == 'icon' else mountain if role == 'placeholder' else diamond
                c = ((36 + state * 12, 112 + state * 8, 164, 210) if stroke else (0, 0, 0, 0))
            raw.extend(c)
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)

def identity(label):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'iina-ani.examples/' + label))

def layout(name, full):
    components = COMPONENTS if full else ('favorites.works', 'favorites.links')
    pages = []
    for component in components:
        pages.append({'id': identity(name + '/page/' + component), 'title': component, 'root': {'kind': 'component', 'id': identity(name + '/node/' + component), 'componentID': component, 'contractVersion': 1, 'parameters': {}, 'size': {'width': 760, 'height': 640}}})
    return {'schemaVersion': 1, 'pages': pages, 'breakpointLayouts': []}

def main():
    for name in ('minimal', 'full'):
        root = ROOT / name
        motion_path = root / 'motions' / 'page.xml'
        motion_path.parent.mkdir(parents=True, exist_ok=True)
        motion_name = 'slide' if name == 'full' else 'fade'
        motion_path.write_bytes((ROOT.parent / 'PageMotions' / (motion_name + '.xml')).read_bytes())
        assets = {}
        # fontFamily is omitted: use the native system font, never redistribute it.
        theme = {"system": {"fontSize": 14, "spacing": 10, "radius": 8, "borderWidth": 1, "density": "regular", "opacity": 1}, "light": {"foreground": "#172B40", "background": "#F4F8FC", "borderColor": "#49657E"}, "dark": {"foreground": "#EDF5FF", "background": "#182331", "borderColor": "#9AB7D3"}}
        if name == 'full':
            for variant in ('light', 'dark'):
                key = 'background-' + variant
                assets[key] = 'assets/' + key + '.png'
                png(root / assets[key], 'background', dark=variant == 'dark')
                theme[variant]['backgroundAsset'] = key
            for role in ('icon', 'placeholder', 'decoration'):
                for index, state in enumerate(STATES):
                    key = role + '-' + state
                    assets[key] = 'assets/' + key + '.png'
                    png(root / assets[key], role, index)
                theme['system'][role + 'Asset'] = role + '-normal'
            slots = {}
            for slot in SLOTS:
                slots[slot] = {'values': {'radius': 8, 'borderWidth': 1, **{r + 'Asset': r + '-normal' for r in ('icon', 'placeholder', 'decoration')}}, 'states': {state: {'opacity': .55 if state == 'disabled' else 1, 'borderWidth': 2 if state in ('focus', 'selected') else 1, **{r + 'Asset': r + '-' + state for r in ('icon', 'placeholder', 'decoration')}} for state in STATES}}
            save(root / 'components.json', {'slots': slots, 'overrides': {c: {'header': {'values': {'fontSize': 16}, 'states': {'focus': {'borderWidth': 2}}}} for c in COMPONENTS}})
        manifest = {'schemaVersion': 1, 'componentContractVersion': 1, 'minimumAppVersion': '0.8.32', 'id': 'iina-ani.example.' + name, 'version': '1.0.0', 'revision': 0, 'name': 'Contour ' + name.title(), 'author': 'IINA-ANI example contributors', 'license': LICENSE, 'supportedVariants': ['light', 'dark'], 'entryPaths': {'theme': 'theme.json', **({'components': 'components.json'} if name == 'full' else {}), 'pageMotion': 'motions/page.xml'}, 'assets': assets, 'assetAttributions': {k: LICENSE for k in assets}, 'provenance': {}, 'layout': layout(name, name == 'full')}
        save(root / 'manifest.json', manifest)
        save(root / 'theme.json', theme)
        png(root / 'preview.png', 'preview')

if __name__ == '__main__':
    main()
