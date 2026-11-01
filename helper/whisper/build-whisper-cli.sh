#!/bin/sh
# whisper-cli for the Mac, built from whisper.cpp (github.com/ggml-org/whisper.cpp) as one static binary with the Metal
# backend (shaders embedded). Agentgram Helper runs it to turn the owner's voice messages into text on the computer.
set -e
COMMIT=${1:-482279b}
DIR=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
git clone -q https://github.com/ggml-org/whisper.cpp.git "$WORK/whisper.cpp"
cd "$WORK/whisper.cpp" && git checkout -q "$COMMIT"
# newer Metal compilers reject «constexpr» on the bfloat casts of the unary kernels; they do not need it
sed -i '' 's/^inline constexpr /inline /' ggml/src/ggml-metal/kernels/unary.metal
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=ON \
	-DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF \
	-DGGML_NATIVE=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
cmake --build build -j 8 --target whisper-cli
cp build/bin/whisper-cli "$DIR/whisper-cli"
rm -rf "$WORK"
