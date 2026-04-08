#!/bin/sh
set -eu

MISHKAN_SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
. "${MISHKAN_SCRIPT_DIR}/helpers.sh"

root-only

cleanup() {
	cd /
	zunmount zshemot/minhagim || true
	zunmount zshemot/sinai || true
	zunmount zshemot/torah || true
	cd --
}
trap cleanup EXIT

system_name="${1:-}"
if [ -z "${system_name}" ]; then
	error "No system name provided\n" || exit
fi
sys_env="MAKE_SRC_ENV=/zshemot/minhagim/${system_name}.env"
if [ ! -f "${sys_env}" ]; then
	confirm "No system environment file found at: '${sys_env}'" || exit
	sys_env=""
fi

allow_broken_git="${2:-No}"	

stage_1_info_string="Stage 1: Build\n"
stage_1_info_string="${stage_1_info_string}\tSystem: ${system_name}\n"
stage_1_info_string="${stage_1_info_string}\tSpecial Environment Config: ${sys_env:-No}\n"
stage_1_info_string="${stage_1_info_string}\tAllow new repo creation?: ${allow_broken_git}\n"
confirm "${stage_1_info_string}" || exit

# Mount the build location
zmount zshemot/sinai
cd /zshemot/sinai || exit 1
# Make sure the directory is a git repo
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
	if yesish "${allow_broken_git}" ; then
		confirm "Building new git in: $(pwd)" || exit
		git init -b trunk
	else
		cd --
		error "bad git repo, and not allowed to make one here\n" || exit
	fi
fi

# Clear it entirely for the new artifact
confirm "Clearing git repo in: $(pwd)" || exit
clear-mtree .
git rm -rf . || true
git clean -fxd
cd --

# Mount the source tree
zmount zshemot/torah
# Build the git repo, or refresh it
cd /zshemot/torah || exit 1
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
	git pull
else
	if yesish "${allow_broken_git}" ; then
		# TODO: choose branch
		confirm "Cloning releng/15.0 into $(pwd)" || exit
		git clone https://git.freebsd.org/src.git -b releng/15.0 .
	else
		cd --
		error "bad git repo, and not allowed to make one here\n" || exit
	fi	
fi

# Mount the build env locations
zmount zshemot/minhagim

# TODO: user selectable system build
confirm "Building...\n\tWorld..." || exit
make ${sys_env:+"${sys_env}"} -j12 buildworld
confirm "\tKernel..." || exit
make ${sys_env:+"${sys_env}"} -j12 buildkernel
confirm "Installing...\n\tKernel..." || exit
make ${sys_env:+"${sys_env}"} DESTDIR=/zshemot/sinai -j12 installkernel
confirm "\tWorld..." || exit
make ${sys_env:+"${sys_env}"} DESTDIR=/zshemot/sinai -j12 installworld
confirm "\tDistribution..." || exit
make ${sys_env:+"${sys_env}"} DESTDIR=/zshemot/sinai -j12 distribution

# We can also leave torah since we don't need source any more
cd --
artifact_name="$(get-artifact-name /zshemot/torah)"
confirm "Generated artifact: ${artifact_name}" || exit
zunmount zshemot/torah

# Move to the built artifact
cd /zshemot/sinai || exit 1

# Generate the crucial mtree
confirm "Generating mtree"
ignore_file="/zshemot/minhagim/${system_name}.mtreeignore"
if [ ! -f "${ignore_file}" ]; then 
	echo "There's no ignore file at: ${ignore_file}, trying fallback..."
	ignore_file="/zshemot/minhagim/sinai.mtreeignore"
	if [ ! -f "${ignore_file}" ]; then
		error "Fallback file ${ignore_file} missing!\n" || exit
	fi
fi
generate-mtree . "${ignore_file}"

# We're done with minhagim now that we've built the config
zunmount zshemot/minhagim

specialize-dirs "var/" "tmp/" "usr/local/" "entropy"

# And add everything to the git
git add .

git commit -m "${artifact_name}"
cd --
zunmount zshemot/sinai
confirm "Done!"
