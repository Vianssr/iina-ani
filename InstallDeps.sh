#!/bin/bash

REPO=xjbeta/iina-plugin-danmaku

if [ -n "${1:-}" ]; then
  gh release download "$1" --repo "$REPO" --pattern 'iina-plugin-danmaku.iinaplgz' --dir IINA-ANI --clobber
else
  gh release download --repo "$REPO" --pattern 'iina-plugin-danmaku.iinaplgz' --dir IINA-ANI --clobber
fi

( cd IINA-ANI/WebFiles/ && npm install )

if [ "${CI:-}" = "true" ]; then
  read -r VERSION BUILD <<< $(unzip -p IINA-ANI/iina-plugin-danmaku.iinaplgz Info.json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['version'],d['ghVersion'])")
  sed -i '' "s/static let internalPluginVersion = \"[^\"]*\"/static let internalPluginVersion = \"$VERSION\"/" IINA-ANI/Features/Playback/IINAApp.swift
  sed -i '' "s/static let internalPluginBuild = [0-9]*/static let internalPluginBuild = $BUILD/" IINA-ANI/Features/Playback/IINAApp.swift
fi
