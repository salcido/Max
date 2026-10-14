#!/bin/bash
#
# Builds the third-party frameworks Max links against as native arm64 frameworks
# and installs them into ./Frameworks (which is git-ignored).
#
# Usage: Scripts/build_frameworks.sh [work dir]
#
# Requires Xcode, Homebrew bash (for associative arrays) or bash >= 4, cmake, curl and git.
# Most libraries are built with the Xcode projects from sbooth/AudioFrameworks; TagLib, mp4v2
# and Monkey's Audio are built from newer API-compatible releases because the projects in
# AudioFrameworks no longer match the sources they pin.

set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
	exec /opt/homebrew/bin/bash "$0" "$@"
fi

MAX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$MAX_DIR/build/frameworks}"
DEST="$MAX_DIR/Frameworks"
AF="$WORK/AudioFrameworks"
OUT="$WORK/out"
REL="$OUT/Release"

ARCH=arm64
MIN_OS=11.0

AUDIOFRAMEWORKS_COMMIT=b1d57b7
TAGLIB_VERSION=1.13.1
MP4V2_VERSION=2.1.3
MAC_SDK_URL="https://web.archive.org/web/20200416194926id_/https://monkeysaudio.com/files/MAC_SDK_520.zip"

mkdir -p "$WORK" "$OUT/logs"

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

fetch_sources() {
	rm -rf "$AF"
	git clone -q https://github.com/sbooth/AudioFrameworks.git "$AF"
	git -C "$AF" checkout -q "$AUDIOFRAMEWORKS_COMMIT"

	# Reuse fetch_sources.sh for its download/patch helpers, but with the library versions the
	# later AudioFrameworks commits moved to and only the libraries Max uses.
	sed -E -e 's/^FLAC_VERSION=.*/FLAC_VERSION="1.3.3"/' \
	       -e 's/^LAME_VERSION=.*/LAME_VERSION="3.100"/' \
	       -e 's/^SNDFILE_VERSION=.*/SNDFILE_VERSION="1.0.28"/' \
	       -e '/^clean$/,$d' "$AF/fetch_sources.sh" > "$WORK/fetch.sh"
	cat >> "$WORK/fetch.sh" <<-'EOF'
	fetch_flac_xz() {
		curl -sL "https://downloads.xiph.org/releases/flac/flac-${FLAC_VERSION}.tar.xz" | tar -xJ -C flac
		mv "flac/flac-${FLAC_VERSION}" flac/flac-src
	}
	fetch_cuetools; fetch_discid; fetch_flac_xz; fetch_lame; fetch_mad; fetch_musepack
	fetch_ogg; fetch_sndfile; fetch_speex; fetch_vorbis; fetch_wavpack
	EOF
	(cd "$AF" && bash "$WORK/fetch.sh")

	curl -sL "https://github.com/taglib/taglib/archive/refs/tags/v${TAGLIB_VERSION}.tar.gz" | tar -xz -C "$WORK"
	curl -sL "https://github.com/enzo1982/mp4v2/archive/refs/tags/v${MP4V2_VERSION}.tar.gz" | tar -xz -C "$WORK"

	rm -rf "$WORK/mac-sdk" && mkdir -p "$WORK/mac-sdk"
	curl -sL -o "$WORK/mac-sdk.zip" "$MAC_SDK_URL"
	tar -xf "$WORK/mac-sdk.zip" -C "$WORK/mac-sdk"
}

# ---------------------------------------------------------------------------
# arm64 fixes
# ---------------------------------------------------------------------------

patch_sources() {
	# libmad: the Intel fixed-point asm was selected for every little-endian CPU
	perl -0pi -e 's/#if __BIG_ENDIAN__\n# define FPM_PPC\n#else\n# define FPM_INTEL\n#endif/#if __BIG_ENDIAN__\n# define FPM_PPC\n#elif defined(__i386__) || defined(__x86_64__)\n# define FPM_INTEL\n#else\n# define FPM_64BIT\n#endif/g' \
		"$AF/mad/libmad-src/fixed.h" "$AF/mad/libmad-src/mad.h"

	# Speex, LAME: SSE only on x86
	perl -0pi -e 's/#ifndef __BIG_ENDIAN__\n# define _USE_SSE/#if defined(__SSE__)\n# define _USE_SSE/' "$AF/speex/config.h"
	perl -pi -e 's/^#define HAVE_XMMINTRIN_H 1/#if defined(__SSE__)\n#define HAVE_XMMINTRIN_H 1\n#endif/' "$AF/lame/config.h"
	local xmm="$AF/lame/lame-src/libmp3lame/vector/xmm_quantize_sub.c"
	{ printf '#if defined(__SSE__)\n'; cat "$xmm"; printf '\n#endif\n'; } > "$xmm.new" && mv "$xmm.new" "$xmm"

	# FLAC: x86 intrinsics only on x86_64; enable Ogg FLAC (Max uses FLAC__stream_*_init_ogg_file)
	perl -pi -e 's/^#define (FLAC__CPU_X86_64|FLAC__USE_AVX|HAVE_CPUID_H|HAVE_X86INTRIN_H) 1/#if defined(__x86_64__)\n#define $1 1\n#endif/; s/^#define FLAC__HAS_X86INTRIN 1/#if defined(__x86_64__)\n#define FLAC__HAS_X86INTRIN 1\n#else\n#define FLAC__HAS_X86INTRIN 0\n#endif/; s/^#define FLAC__HAS_OGG 0/#define FLAC__HAS_OGG 1/' \
		"$AF/flac/config.h"

	# Vorbis: the project's ogg.framework reference is dangling, so link it explicitly
	perl -pi -e 's/^(\t+)PRODUCT_NAME = vorbis;$/$1PRODUCT_NAME = vorbis;\n$1OTHER_LDFLAGS = "-framework ogg";/' \
		"$AF/vorbis/vorbis.xcodeproj/project.pbxproj"

	# Monkey's Audio: Obj-C BOOL is bool on arm64; the SDK typedef must match it for C++ mangling
	local mac="$WORK/mac-sdk/Source/Shared"
	perl -i -pe 's/\r\n/\n/' "$mac/All.h" "$mac/NoWindows.h"
	grep -q '^#define PLATFORM_APPLE' "$mac/All.h" || \
		perl -0pi -e 's/(\*{20,}\/\n)(#if !defined\(PLATFORM_WINDOWS\))/$1#define PLATFORM_APPLE\n$2/' "$mac/All.h"
	perl -0pi -e 's|    typedef signed char BOOL;  // this is the way it.s defined in Obj-C|    #if defined(__OBJC_BOOL_IS_BOOL) && __OBJC_BOOL_IS_BOOL\n    typedef bool BOOL;         // Obj-C on arm64\n    #else\n    typedef signed char BOOL;  // this is the way it\x27s defined in Obj-C\n    #endif|' \
		"$mac/NoWindows.h"
}

# ---------------------------------------------------------------------------
# Builds
# ---------------------------------------------------------------------------

declare -A XCODE_TARGET=(
	[ogg]=ogg.framework [flac]=Framework [vorbis]=vorbis.framework [speex]=speex.framework
	[lame]=Framework [mad]=mad.framework [wavpack]=Framework [sndfile]=sndfile.framework
	[musepack]=mpcdec.framework [shorten]=shorten.framework [cuetools]=cuetools.framework
	[discid]=discid [cdparanoia]=cdparanoia.framework
)

build_xcode() {
	local lib=$1 extra=()
	[[ $lib == flac ]] && extra=(OTHER_LDFLAGS="-framework ogg")
	echo "Building $lib"
	xcodebuild -project "$AF/$lib/$lib.xcodeproj" -target "${XCODE_TARGET[$lib]}" -configuration Release \
		ARCHS=$ARCH ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=$MIN_OS \
		SYMROOT="$OUT" OBJROOT="$OUT/obj" CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
		"${extra[@]}" \
		OTHER_CFLAGS='$(inherited) -fcommon -Wno-error -Wno-parentheses -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-function-pointer-types' \
		FRAMEWORK_SEARCH_PATHS="$REL" > "$OUT/logs/$lib.log" 2>&1 \
		|| { echo "  failed, see $OUT/logs/$lib.log"; exit 1; }
}

# Wraps a dylib and its headers as <name>.framework
make_framework() {
	local name=$1 dylib=$2 headers=$3 f="$REL/$1.framework"
	rm -rf "$f" && mkdir -p "$f/Versions/A/Headers" "$f/Versions/A/Resources"
	cp "$dylib" "$f/Versions/A/$name"
	install_name_tool -id "@rpath/$name.framework/Versions/A/$name" "$f/Versions/A/$name"
	cp -R "$headers"/. "$f/Versions/A/Headers/"
	cat > "$f/Versions/A/Resources/Info.plist" <<-EOF
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>org.sbooth.$name</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	</dict></plist>
	EOF
	ln -sfn A "$f/Versions/Current"
	for x in "$name" Headers Resources; do ln -sfn "Versions/Current/$x" "$f/$x"; done
}

build_cmake() {
	local name=$1 src=$2 b="$OUT/cmake-$1"; shift 2
	echo "Building $name"
	rm -rf "$b"
	{
		cmake -S "$src" -B "$b" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=$ARCH \
			-DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_OS -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
			-DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX="$b/install" "$@"
		cmake --build "$b" -j "$(sysctl -n hw.ncpu)"
		cmake --install "$b"
	} > "$OUT/logs/$name.log" 2>&1 || { echo "  failed, see $OUT/logs/$name.log"; exit 1; }
	make_framework "$name" "$(find "$b/install/lib" -maxdepth 1 -name 'lib*.dylib' -type f | head -1)" "$b/install/include/$name"
}

build_mac() {
	echo "Building mac"
	local src="$WORK/mac-sdk/Source" hdr="$OUT/mac-headers" lib="$OUT/libmac.dylib"
	xcrun clang++ -std=gnu++11 -O2 -arch $ARCH -mmacosx-version-min=$MIN_OS -dynamiclib -w \
		-I"$src/Shared" -I"$src/MACLib" -I"$src/MACLib/Old" \
		"$src"/MACLib/*.cpp "$src"/MACLib/Old/*.cpp \
		"$src"/Shared/{CRC,CharacterHelper,CircleBuffer,GlobalFunctions,StdLibFileIO}.cpp \
		-o "$lib" > "$OUT/logs/mac.log" 2>&1 || { echo "  failed, see $OUT/logs/mac.log"; exit 1; }
	rm -rf "$hdr" && mkdir -p "$hdr"
	for h in APECompress.h APEDecompress.h APETag.h All.h CRC.h CharacterHelper.h CircleBuffer.h \
	         GlobalFunctions.h ID3Genres.h IO.h MACLib.h NoWindows.h RollBuffer.h SmartPtr.h \
	         StdLibFileIO.h StdString.h Timer.h; do
		cp "$(find "$src/Shared" "$src/MACLib" -maxdepth 1 -name "$h" | head -1)" "$hdr/"
	done
	make_framework mac "$lib" "$hdr"
}

fetch_sources
patch_sources

for lib in ogg flac vorbis speex lame mad wavpack sndfile musepack shorten cuetools discid cdparanoia; do
	build_xcode $lib
done

build_cmake taglib "$WORK/taglib-$TAGLIB_VERSION" -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF -DBUILD_BINDINGS=OFF -DWITH_ZLIB=OFF
build_cmake mp4v2 "$WORK/mp4v2-$MP4V2_VERSION" -DBUILD_UTILS=OFF
build_mac

# WavPack's ChunkHeader collides with CarbonCore's; the original Max framework renamed it too
sed -i '' -E 's/\} ChunkHeader;/} WPChunkHeader;/' "$REL/wavpack.framework/Versions/A/Headers/wavpack.h"

mkdir -p "$DEST"
for fw in FLAC cdparanoia cuetools discid lame mac mad mp4v2 mpcdec ogg shorten sndfile speex taglib vorbis wavpack; do
	rm -rf "$DEST/$fw.framework"
	cp -R "$REL/$fw.framework" "$DEST/"
	printf '%-11s %s\n' "$fw" "$(lipo -archs "$DEST/$fw.framework/$fw")"
done
echo "Frameworks installed in $DEST"
