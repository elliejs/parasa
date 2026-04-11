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
	confirm "WARNING: No system environment file found at: '${SYSTEM_MAKE_ENV}'" || exit
	SYSTEM_MAKE_ENV=""
fi

stage_1_info_string="INFO: Stage 1: Build\n"
stage_1_info_string="${stage_1_info_string}INFO:\tSystem: ${SYSTEM_NAME}\n"
stage_1_info_string="${stage_1_info_string}INFO:\tSpecial Environment Config: ${SYSTEM_MAKE_ENV:-No}\n"
stage_1_info_string="${stage_1_info_string}INFO:\tAllow new repo creation?: ${NEW_GIT}\n"
yesish "${QUIET}" || confirm "${stage_1_info_string}" || exit

# Mount the build location
zmount zshemot/sinai
cd /zshemot/sinai || exit 1
# Make sure the directory is a git repo
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
	if yesish "${NEW_GIT}" ; then
		confirm "INFO: Building new git in: $(pwd)" || exit
		yesish "${DRY_RUN}" || git init -b trunk
	else
		cd --
		error "bad git repo, and not allowed to make one here\n" || exit
	fi
fi

# Clear it entirely for the new artifact
yesish "${QUIET}" || confirm "INFO: Clearing git repo in: $(pwd)" || exit
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
	if noish "${DRY_RUN}"; then
		if git pull 2>&1 | grep -q "Already up to date." && yesish "${CRON_MODE}"; then
			exit 0
		fi
	fi
else
	if yesish "${NEW_GIT}" ; then
		# TODO: choose branch
		confirm "INFO: Cloning releng/15.0 into $(pwd)" || exit
		yesish "${DRY_RUN}" || git clone https://git.freebsd.org/src.git -b releng/15.0 .
	else
		cd --
		error "bad git repo, and not allowed to make one here\n" || exit
	fi	
fi

# Mount the build env locations
zmount zshemot/minhagim

# TODO: user selectable system build
yesish "${QUIET}" || confirm "INFO: Building...\nINFO:\tWorld..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} -j12 buildworld
yesish "${QUIET}" || confirm "INFO: \tKernel..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} -j12 buildkernel
yesish "${QUIET}" || confirm "INFO: Installing...\nINFO:\tKernel..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} DESTDIR=/zshemot/sinai -j12 installkernel
yesish "${QUIET}" || confirm "INFO:\tWorld..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} DESTDIR=/zshemot/sinai -j12 installworld
yesish "${QUIET}" || confirm "INFO:\tDistribution..." || exit
yesish "${DRY_RUN}" || make ${SYSTEM_MAKE_ENV:+"${SYSTEM_MAKE_ENV}"} DESTDIR=/zshemot/sinai -j12 distribution

# We can also leave torah since we don't need source any more
cd --
artifact_name="$(get-artifact-name /zshemot/torah)"
yesish "${QUIET}" || confirm "INFO: Generated artifact: ${artifact_name}" || exit
zunmount zshemot/torah

# Move to the built artifact
cd /zshemot/sinai || exit 1

# Generate the crucial mtree
yesish "${QUIET}" || confirm "INFO: Generating mtree" || exit
# FWIW, 99% of the time, this is just a file to exclude .git
# It's really only a file because piping in a string doesn't work
MTREE_IGNORE_FILE="/zshemot/minhagim/${SYSTEM_NAME}.mtreeignore"
if [ ! -f "${MTREE_IGNORE_FILE}" ]; then 
	yesish "${QUIET}" || echo "INFO: There's no ignore file at: ${MTREE_IGNORE_FILE}, trying fallback..."
	MTREE_IGNORE_FILE="/zshemot/minhagim/sinai.mtreeignore"
	if [ ! -f "${MTREE_IGNORE_FILE}" ]; then
		error "Fallback file ${MTREE_IGNORE_FILE} missing!\n" || exit
	fi
fi
yesish "${DRY_RUN}" || generate-mtree . "${MTREE_IGNORE_FILE}"

yesish "${DRY_RUN}" || {
	# TODO:
	# TORAH_IGNORE is a curated list of dirs we zfs mount into the final dataset that do
	# actually exist in torah too, so we want to selectively track a *few* of the files
	# in the dir, but not most of them. (eg var/ which is mostly generated trash). There's
	# technically a way we can automate this by calling sysgit (helpers.sh) and looking at
	# the generated .git/info/exclude ignores from the mounts, and then selectively
	# re-force-adding the files from torah which appear in these ignored dirs. Anything else
	# in that torah ignore file (eg entropy) is hand added and could just be in the .gitignore
	[ -n "${TORAH_IGNORE_FILE}" ] || TORAH_IGNORE_FILE="/zshemot/minhagim/${SYSTEM_NAME}.torahignore"
	if [ -f "${TORAH_IGNORE_FILE}" ]; then
		ignore-but-keep-torah "/zshemot/sinai" "${TORAH_IGNORE_FILE}"
	else
		yesish "${QUIET}" || confirm "WARNING: ${TORAH_IGNORE_FILE} not found." || exit
	fi
	# And add everything to the git
	git add .
	yesish "${QUIET}" || confirm "INFO: Committing ${artifact_name} to Sinai" || exit
	git commit -m "${artifact_name}"
}

zunmount zshemot/minhagim || true

cd --
zunmount zshemot/sinai || true
yesish "${QUIET}" || confirm "INFO: Done!"
