#!/usr/bin/env bash
# Build Ventura-compatible replacements for the embedded Intel Node addons.
set -euo pipefail

output_dir=$(cd "${1:?Supply an existing output directory}" && pwd)
sherpa_commit=11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf
sherpa_version=1.13.8
builtin_commit=a58d3599a2e551d7d706d1ff796c9fd4bbaff63c
node_addon_api_version=8.9.0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"

curl -fsSL --retry 3 "https://codeload.github.com/k2-fsa/sherpa-onnx/tar.gz/$sherpa_commit" -o source.tgz
curl -fsSL --retry 3 "https://registry.npmjs.org/sherpa-onnx-darwin-x64/-/sherpa-onnx-darwin-x64-$sherpa_version.tgz" -o runtime.tgz
curl -fsSL --retry 3 "https://codeload.github.com/deepseek-ai/dsh-node-addon-require-builtin/tar.gz/$builtin_commit" -o builtin.tgz
curl -fsSL --retry 3 "https://registry.npmjs.org/node-addon-api/-/node-addon-api-$node_addon_api_version.tgz" -o headers.tgz
shasum -a 256 -c <<'CHECKSUMS'
0a8db6c55dd318f4a688faba85f7760b99a6c92e8ef8864479d418531bee1ac2  source.tgz
3e583d3423160cb8a0f9316008e293ad9a6b66c63e1966ad399a88300390fbaa  runtime.tgz
286616f15e4f12013988e45ad27a69b4968a9f059c8bd351e412505230577948  builtin.tgz
19b87e2ce3a77fec0121ac97d7db088aae28aacfff481adab50d5f61b70e68f4  headers.tgz
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
sherpa_output="$output_dir/sherpa-onnx-darwin-x64/$sherpa_version"
mkdir -p "$sherpa_output"
cp package/sherpa-onnx.node "$sherpa_output/"

tar -xzf builtin.tgz
cd "dsh-node-addon-require-builtin-$builtin_commit/packages/native"
# Match the Electron fingerprint shipped by the 0.1.10 npm prebuild.
python3 - <<'PYTHON' > "$scratch/builtin-sources.txt"
import json
from pathlib import Path

profiles = Path('src/runtime_context/runtime_profile.cc')
source = profiles.read_text()
array = 'std::array<ElectronProfileSpec, 4>'
next_entry = '    {"45.0.0-alpha.6",'
assert source.count(array) == source.count(next_entry) == 1
source = source.replace(array, 'std::array<ElectronProfileSpec, 5>')
source = source.replace(next_entry,
    '    {"44.11.5", 24, 22, 3, "15.2.124.45-electron.0",\n'
    '     "electron-44.11 tagged default=0"},\n' + next_entry)
profiles.write_text(source)
target = json.loads(Path('binding.gyp').read_text())['targets'][0]
print(*target['sources'], *target['conditions'][0][2]['sources'], sep='\n')
PYTHON
builtin_sources=()
while IFS= read -r source; do
  builtin_sources+=("$source")
done < "$scratch/builtin-sources.txt"

builtin_output="$output_dir/node-addon-require-builtin-darwin-x64/0.1.10/prebuilt"
mkdir -p "$builtin_output"
builtin="$builtin_output/darwin-x64-napi-v9.node"
xcrun clang++ -arch x86_64 -mmacosx-version-min=13.0 -std=c++17 -O2 \
  -bundle -undefined dynamic_lookup -fvisibility=hidden -fno-exceptions \
  -DNAPI_VERSION=9 -DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS -DNARB_BACKEND=1 -DNARB_PRODUCT=1 \
  -I "$node_headers" -I "$scratch/headers" "${builtin_sources[@]}" -o "$builtin"
codesign --sign - --force "$builtin"
node -e 'const addon = require(process.argv[1]); const assert = require("node:assert/strict"); assert.equal(typeof addon.requireBuiltin("internal/modules/esm/loader").getOrInitializeCascadedLoader, "function")' "$builtin"
