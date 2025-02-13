#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

source Packaging/OpenDingux/targets.sh
source Packaging/OpenDingux/package-opk.sh

usage() {
  >&2 echo "Usage: build.sh [--profile-generate|--profile-use] [--profile-dir PATH] [target]"
  >&2 usage_target
}

declare -rA BUILDROOT_REPOS=(
	[lepus]=https://github.com/OpenDingux/buildroot.git
	[retrofw]=https://github.com/retrofw/buildroot.git
	[rg99]=https://github.com/OpenDingux/buildroot.git
	[rg350]=https://github.com/OpenDingux/buildroot.git
	[gkd350h]=https://github.com/tonyjih/RG350_buildroot.git
)
declare -rA BUILDROOT_DEFCONFIGS=(
	[lepus]='od_lepus_defconfig BR2_EXTERNAL=board/opendingux'
	[retrofw]='RetroFW_defconfig BR2_EXTERNAL=retrofw'
	[rg99]='od_rs90_defconfig BR2_EXTERNAL=board/opendingux'
	[rg350]='od_gcw0_defconfig BR2_EXTERNAL=board/opendingux'
	[gkd350h]='rg350_defconfig BR2_EXTERNAL=board/opendingux'
)

declare TARGET
declare BUILD_DIR
declare BUILDROOT
declare BUILDROOT_TARGET
declare TOOLCHAIN

declare -a CMAKE_CONFIGURE_OPTS=()
declare PROFILE_GENERATE=0
declare PROFILE_USE=0
declare PROFILE_DIR="%q{HOME}/devilutionx-profile"
declare BUILD_TYPE=release

main() {
	parse_args "$@"
	BUILD_DIR="build-${TARGET}"
	BUILDROOT_TARGET="$TARGET"

	# If a TOOLCHAIN environment variable is set, just use that.
	if [[ -z ${TOOLCHAIN:-} ]]; then
		BUILDROOT="${BUILDROOT:-$HOME/devilutionx-buildroots/$BUILDROOT_TARGET}"
		TOOLCHAIN="${BUILDROOT}/output/host"
	fi

	>&2 echo "Building for target ${TARGET} in ${BUILD_DIR}"
	set -x
	if [[ -n ${BUILDROOT:-} ]]; then
		prepare_buildroot
		make_buildroot
	fi
	build
	package_opk
}

parse_args() {
	local -a positional=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--profile-generate)
			PROFILE_GENERATE=1
			shift
			;;
		--profile-use)
			PROFILE_USE=1
			shift
			;;
		--profile-dir)
			shift
			if [[ $# -eq 0 ]]; then
				usage
				exit 64
			fi
			PROFILE_DIR="$1"
			shift
			;;
		-*|--*)
			>&2 echo "Error: unknown argument $1"
			>&2 echo
			usage
			exit 64
			;;
		*)
			positional+=("$1")
			shift
			;;
		esac
	done
	if [[ ${#positional[@]} -ne 1 ]] || ! check_target "${positional[0]}"; then
		>&2 echo "Error: target is required"
		>&2 echo
		usage
		exit 64
	fi
	TARGET="${positional[0]}"

	if (( PROFILE_GENERATE )) && (( PROFILE_USE )); then
		>&2 echo "Error: at most one of --profile-use and --profile-generate is allowed"
		exit 64
	fi
	if (( PROFILE_GENERATE )); then
		CMAKE_CONFIGURE_OPTS+=(
			"-DDEVILUTIONX_PROFILE_GENERATE=ON"
			"-DDEVILUTIONX_PROFILE_DIR=${PROFILE_DIR}"
		)
		OPK_DESKTOP_NAME="DevilutionX PG"
		OPK_DESKTOP_EXEC="profile-generate.sh"
		OPK_EXTRA_FILES=(
			Packaging/OpenDingux/profile-generate.sh
			test/fixtures/timedemo/WarriorLevel1to2/demo_0.dmo
			test/fixtures/timedemo/WarriorLevel1to2/demo_0_reference_spawn_0.sv
			test/fixtures/timedemo/WarriorLevel1to2/spawn_0.sv
		)
	fi
	if (( PROFILE_USE )); then
		CMAKE_CONFIGURE_OPTS+=(
			"-DDEVILUTIONX_PROFILE_USE=ON"
			"-DDEVILUTIONX_PROFILE_DIR=${PROFILE_DIR}"
		)
	fi
}

prepare_buildroot() {
	if [[ -d $BUILDROOT ]]; then
		return
	fi
	if [[ "${BUILDROOT_REPOS[$BUILDROOT_TARGET]}" == *.tar.gz ]]; then
		mkdir -p "$BUILDROOT"
		curl -L --fail "${BUILDROOT_REPOS[$BUILDROOT_TARGET]}" | \
			tar -xz --strip-components 1 -C "$BUILDROOT"
	else
		git clone --depth=1 "${BUILDROOT_REPOS[$BUILDROOT_TARGET]}" "$BUILDROOT"
	fi
	cd "$BUILDROOT"
	ln -s ../shared-dl dl

	# Work around a BR2_EXTERNAL initialization bug in older buildroots.
	mkdir -p output
	touch output/.br-external.mk
	make ${BUILDROOT_DEFCONFIGS[$BUILDROOT_TARGET]}
	cd -
}

make_buildroot() {
	cd "$BUILDROOT"
	BR2_JLEVEL=0 make toolchain sdl
	cd -
}

cmake_configure() {
	# libzt uses `-fstack-protector` GCC flag by default.
	# We disable `-fstack-protector` because it isn't supported by target libc.
	cmake -S. -B"$BUILD_DIR" \
		-G "Unix Makefiles" \
		"-DTARGET_PLATFORM=$TARGET" \
		-DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}/usr/share/buildroot/toolchainfile.cmake" \
		-DBUILD_TESTING=OFF \
		-DDEVILUTIONX_SYSTEM_LIBSODIUM=OFF \
		-DDEVILUTIONX_SYSTEM_BZIP2=OFF \
		-DSTACK_PROTECTOR=OFF \
		"${CMAKE_CONFIGURE_OPTS[@]}"
}

cmake_build() {
	BR_CACHE_DIR="${HOME}/.buildroot-ccache" cmake --build "$BUILD_DIR" -j "$(getconf _NPROCESSORS_ONLN)"
}

strip_bin() {
	"${TOOLCHAIN}/usr/bin/"*-linux-strip -s -R .comment -R .gnu.version "${BUILD_DIR}/devilutionx"
}

build_debug() {
	cmake_configure -DCMAKE_BUILD_TYPE=Debug -DASAN=OFF -DUBSAN=OFF -DCMAKE_CXX_FLAGS_DEBUG="-g -fno-omit-frame-pointer" "$@"
	cmake_build
}

build_relwithdebinfo() {
	cmake_configure -DCMAKE_BUILD_TYPE=RelWithDebInfo "$@"
	cmake_build
}

build_minsizerel() {
	cmake_configure -DCMAKE_BUILD_TYPE=MinSizeRel "$@"
	cmake_build
	strip_bin
}

build_release() {
	cmake_configure -DCMAKE_BUILD_TYPE=Release "$@"
	cmake_build
	strip_bin
}

build() {
	rm -f "${BUILD_DIR}/CMakeCache.txt"
	build_"$BUILD_TYPE" "$@"
}

main "$@"
