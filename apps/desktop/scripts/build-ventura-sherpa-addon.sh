#!/usr/bin/env bash
# Build the Intel Node binding against the speech runtime libraries shipped by npm.
set -euo pipefail

output_dir=$(cd "${1:?Supply an existing output directory}" && pwd)
sherpa_commit=11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf
sherpa_version=1.13.8
node_addon_api_version=8.5.0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"

curl -fsSL --retry 3 "https://codeload.github.com/k2-fsa/sherpa-onnx/tar.gz/$sherpa_commit" -o source.tgz
curl -fsSL --retry 3 "https://registry.npmjs.org/sherpa-onnx-darwin-x64/-/sherpa-onnx-darwin-x64-$sherpa_version.tgz" -o runtime.tgz
curl -fsSL --retry 3 "https://registry.npmjs.org/node-addon-api/-/node-addon-api-$node_addon_api_version.tgz" -o headers.tgz
shasum -a 256 -c <<'CHECKSUMS'
0a8db6c55dd318f4a688faba85f7760b99a6c92e8ef8864479d418531bee1ac2  source.tgz
3e583d3423160cb8a0f9316008e293ad9a6b66c63e1966ad399a88300390fbaa  runtime.tgz
d12f07c8162283b6213551855f1da8dac162331374629830b5e640f130f07910  headers.tgz
CHECKSUMS

source_dir="sherpa-onnx-$sherpa_commit"
tar -xzf source.tgz
tar -xzf runtime.tgz
mkdir headers
tar -xzf headers.tgz -C headers --strip-components 1
node_headers="$(node -p 'require("node:path").resolve(process.execPath, "../../include/node")')"
test -f "$node_headers/node_api.h"
xcrun clang++ -arch x86_64 -mmacosx-version-min=13.0 -std=c++17 -O2 \
  -bundle -undefined dynamic_lookup -Wl,-rpath,@loader_path \
  -I "$node_headers" -I headers -I "$source_dir" \
  "$source_dir"/scripts/node-addon-api/src/*.cc \
  -L package -lsherpa-onnx-c-api -lonnxruntime \
  -o package/sherpa-onnx.node
codesign --sign - --force package/sherpa-onnx.node
node -e 'require("./package/sherpa-onnx.node")'
mkdir -p "$output_dir/$sherpa_version"
cp package/sherpa-onnx.node "$output_dir/$sherpa_version/"
