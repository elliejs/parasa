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

print_help() {

}

NEW_GIT="No"
DRY_RUN="No"
QUIET="No"
SYSTEM_NAME=""
CRON_MODE="No"
TORAH_IGNORE_FILE=""
while getopts ":ndqchx:s:" opt; do
	case "${opt}" in
		n) NEW_GIT="Yes" ;;
		d) DRY_RUN="Yes" ;;
		q) QUIET="Yes"   ;;
		c)
			QUIET="Yes"
			CRON_MODE="Yes"
			;;
		h)
			print_help
			;;
		x)
			TORAH_IGNORE_FILE="${OPTARG}"
			;;
		s)
			SYSTEM_NAME="${OPTARG}"
			;;
		\?)
			printf "Error: -%s is an unrecognized flag.\n" "${OPTARG}" >&2
			exit 1
			;;
		:)
			case "${OPTARG}" in
				s)
					echo "System name must be some string."
					;;
			esac
			exit 1
	esac
done

shift $((OPTIND - 1))

if [ -z "${SYSTEM_NAME}" ]; then
	error "No system name provided\n" || exit
fi

SYSTEM_MAKE_ENV="MAKE_SRC_ENV=/zshemot/minhagim/${SYSTEM_NAME}.env"
if [ ! -f "${SYSTEM_MAKE_ENV}" ]; then
	confirm "No system environment file found at: '${SYSTEM_MAKE_ENV}'" || exit
	SYSTEM_MAKE_ENV=""
fi

stage_1_info_string="Stage 1: Build\n"
stage_1_info_string="${stage_1_info_string}\tSystem: ${SYSTEM_NAME}\n"
stage_1_info_string="${stage_1_info_string}\tSpecial Environment Config: ${SYSTEM_MAKE_ENV:-No}\n"
stage_1_info_string="${stage_1_info_string}\tAllow new repo creation?: ${NEW_GIT}\n"
yesish "${QUIET}" || confirm "${stage_1_info_string}" || exit

# Mount the build location
zmount zshemot/sinai
cd /zshemot/sinai || exit 1
# Make sure the directory is a git repo
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
	if yesish "${NEW_GIT}" ; then
		confirm "Building new git in: $(pwd)" || exit
		yesish "${DRY_RUN}" || git init -b trunk
	else
		cd --
		error "bad git repo, and not allowed to make one here\n" || exit
	fi
fi

# Clear it entirely for the new artifact
yesish "${QUIET}" || confirm "Clearing git repo in: $(pwd)" || exit
yesish "${DRY_RUN}" || {
	clear-mtree .
	git rm -rf . || true
	git clean -fxd
}
cd --

# Mount the source tree
zmount zshemot/torah
# Build the git repo, or refresh it
cd /zshemot/torah || exit 1
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
	yesish "${DRY_RUN}" || git pull
	# TODO: Abort if no new changes
else
	if yesish "${NEW_GIT}" ; then
		# TODO: choose branch
		confirm "Cloning releng/15.0 into $(pwd)" || exit
		yesish "${DRY_RUN}" || git clone https://git.freebsd.org/src.git -b releng/15.0 .
	else
		cd --
		error "bad git repo, and not allowed to make one here\n" || exit
	fi	
fi

# Mount the build env locations
zmount zshemot/minhagim

# TODO: user selectable system build
yesish "${QUIET}" || confirm "Building...\n\tWorld..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} -j12 buildworld
yesish "${QUIET}" || confirm "\tKernel..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} -j12 buildkernel
yesish "${QUIET}" || confirm "Installing...\n\tKernel..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} DESTDIR=/zshemot/sinai -j12 installkernel
yesish "${QUIET}" || confirm "\tWorld..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} DESTDIR=/zshemot/sinai -j12 installworld
yesish "${QUIET}" || confirm "\tDistribution..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} DESTDIR=/zshemot/sinai -j12 distribution

# We can also leave torah since we don't need source any more
cd --
artifact_name="$(get-artifact-name /zshemot/torah)"
yesish "${QUIET}" || confirm "Generated artifact: ${artifact_name}" || exit
zunmount zshemot/torah

# Move to the built artifact
cd /zshemot/sinai || exit 1

# Generate the crucial mtree
yesish "${QUIET}" || confirm "Generating mtree"
ignore_file="/zshemot/minhagim/${SYSTEM_NAME}.mtreeignore"
if [ ! -f "${ignore_file}" ]; then 
	echo "There's no ignore file at: ${ignore_file}, trying fallback..."
	ignore_file="/zshemot/minhagim/sinai.mtreeignore"
	if [ ! -f "${ignore_file}" ]; then
		error "Fallback file ${ignore_file} missing!\n" || exit
	fi
fi
yesish "${DRY_RUN}" || generate-mtree . "${ignore_file}"

# We're done with minhagim now that we've built the config
zunmount zshemot/minhagim

yesish "${DRY_RUN}" || {
	[ -n "${TORAH_IGNORE_FILE}" ] || TORAH_IGNORE_FILE="/zshemot/minhagim/${SYSTEM}.torahignore"
	if [ -f "${TORAH_IGNORE_FILE}" ]; then
		ignore-but-keep-torah "/zshemot/sinai" "${TORAH_IGNORE_FILE}"
	else
		echo "No .torahignore file found for ${SYSTEM}."
	fi
	# And add everything to the git
	git add .
	yesish "${QUIET}" || confirm "Committing ${artifact_name} to sinai"
	git commit -m "${artifact_name}"
}
cd --
zunmount zshemot/sinai
yesish "${QUIET}" || confirm "Done!"
