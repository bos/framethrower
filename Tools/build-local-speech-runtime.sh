#!/bin/bash
# Build-time only. End users receive the helper and signed libraries in the app.
set -euo pipefail
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
revision=727d3e7666485e12450746b523bfb4e7f057cc5e
archive_sha=2faadee998fba3a95ba2280258282d90b7f7bbb3ed074c7beb9ec6a3165584e6
arch=${CURRENT_ARCH:-}
# Xcode's application shell phases use undefined_arch; ARCHS describes the
# product. A universal app may include an arm64-only optional helper.
if [[ -z $arch || $arch == undefined_arch ]]; then
    case " ${ARCHS:-$(uname -m)} " in
        *" arm64 "*) arch=arm64 ;;
        *) arch=x86_64 ;;
    esac
fi
if [[ $arch != arm64 ]]; then echo "Local speech: Apple dictation fallback on $arch"; exit 0; fi
cache="${LOCAL_SPEECH_BUILD_CACHE:-$HOME/Library/Caches/FrameThrower/LocalSpeech/runtime-build}"
source_dir="$cache/source-$revision"
build_dir="$cache/build-$revision-$arch"
package_dir="$cache/package-$revision-$arch"
helper="$repo_dir/Tools/LocalSpeech/main.cpp"
fingerprint=$(cat "$helper" "$0" | shasum -a 256 | cut -d ' ' -f 1)
if [[ ! -f "$package_dir/build.fingerprint" ]] || [[ $(cat "$package_dir/build.fingerprint") != "$fingerprint" ]]; then
    mkdir -p "$cache"
    if [[ ! -f "$source_dir/CMakeLists.txt" ]]; then
        archive="$cache/source-$revision.tar.gz.partial"
        trap 'rm -f "$archive"' EXIT
        curl --fail --location --retry 2 "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/$revision" -o "$archive"
        echo "$archive_sha  $archive" | shasum -a 256 --check --status
        unpack="$cache/unpack-$$"; mkdir -p "$unpack"
        tar -xzf "$archive" --strip-components=1 -C "$unpack"
        mv "$unpack" "$source_dir"; rm "$archive"; trap - EXIT
    fi
    cmake -S "$source_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_COREML=OFF -DWHISPER_CURL=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
    cmake --build "$build_dir" --target whisper -j 6
    mkdir -p "$package_dir"
    clang++ -O2 -std=c++17 -arch arm64 -mmacosx-version-min=15.0 -I "$source_dir/include" -I "$source_dir/ggml/include" "$helper" -L "$build_dir/bin" -lwhisper -lggml -lggml-base -Wl,-rpath,@loader_path -o "$package_dir/FrameThrowerSpeech"
    # Copy real versioned libraries and their relative symlinks; no unused parakeet runtime.
    for name in whisper ggml ggml-base ggml-cpu ggml-blas ggml-metal; do
        cp -pP "$build_dir/bin/lib$name"*.dylib "$package_dir/"
    done
    # Strip build-machine lookup paths. All runtime dependencies resolve beside
    # the helper, including on a Mac with no compiler or dependency cache.
    while IFS= read -r lib; do
        if otool -l "$lib" | grep -Fq "path $build_dir/bin (offset"; then
            install_name_tool -delete_rpath "$build_dir/bin" "$lib"
        fi
    done < <(find "$package_dir" -type f -name '*.dylib')
    cp "$source_dir/LICENSE" "$package_dir/whisper-LICENSE.txt"
    printf '%s' "$fingerprint" > "$package_dir/build.fingerprint"
fi
output=${1:-"$repo_dir/build/LocalSpeech"}
mkdir -p "$output"
# A new app build receives the already-built runtime. Signing follows copy.
rsync -a --delete "$package_dir/" "$output/"
identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
if [[ -z $identity ]]; then identity=-; fi
sign_options=runtime
# Hardened library validation needs a real Team ID. Ad-hoc compile/test builds
# have none; production signing retains hardened runtime and matching Team IDs.
if [[ $identity == - ]]; then sign_options=0; fi
while IFS= read -r lib; do codesign --force --sign "$identity" --options "$sign_options" "$lib"; done < <(find "$output" -type f -name '*.dylib')
codesign --force --sign "$identity" --options "$sign_options" "$output/FrameThrowerSpeech"
echo "Local speech runtime: $revision (Metal, arm64)"
