#! /bin/bash
set -euo pipefail

# Mount the build location
zmount zshemot/sinai
cd /zshemot/sinai
# Make sure the directory is a git repo
if ! git rev-parse > /dev/null 2>&1; then
	git init -b trunk
fi
# Clear it entirely for the new artifact
git rm -rf . && git clean -fxd
cd --

# Mount the source tree
zfs set mountpoint=/zshemot/torah zshemot/torah
# Build the git repo, or refresh it
cd /zshemot/torah
if git rev-parse > /dev/null 2>&1; then
	git pull
else
	git clone https://git.freebsd.org/src.git -b releng/15.0 .
	# TODO: choose branch
fi

# Mount the build env locations
zfs set mountpoint=/zshemot/minhagim zshemot/minhagim

# TODO: user selectable system build
SYSTEM="mishkan"
make MAKE_SRC_ENV="/zshemot/minhagim/${SYSTEM}.env" -j12 buildworld
make MAKE_SRC_ENV="/zshemot/minhagim/${SYSTEM}.env" -j12 buildkernel
make MAKE_SRC_ENV="/zshemot/minhagim/${SYSTEM}.env" DESTDIR="zshemot/sinai" -j12 installkernel
make MAKE_SRC_ENV="/zshemot/minhagim/${SYSTEM}.env" DESTDIR="zshemot/sinai" -j12 installworld
make MAKE_SRC_ENV="/zshemot/minhagim/${SYSTEM}.env" DESTDIR="zshemot/sinai" -j12 distribution

# We can also leave torah since we don't need source any more
cd --
ARTIFACT_NAME="$(get-artifact-name /zshemot/torah)"
zfs set mountpoint=none zshemot/torah

# Move to the built artifact
cd /zshemot/sinai
# Generate the crucial mtree
# TODO: refactor to auto-sniff ${CWD}.ignoretree
generate-mtree . /zshemot/minhagim/sinai.mtreeignore

# We're done with minhagim now that we've built the config
zfs set mountpoint=none zshemot/minhagim

# Then make this dir easier to deal with
clear-mtree .
# And add everything to the git
git add .

git commit -m "${ARTIFACT_NAME}"
cd --
zfs set mountpoint=none zshemot/sinai

