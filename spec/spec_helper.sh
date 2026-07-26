# shellcheck shell=sh

# Shared setup for all parasa specs.

spec_helper_precheck() {
  : minimum_version "0.28.1"
}

spec_helper_loaded() {
  :
}

spec_helper_configure() {
  : import 'support/custom_matcher'
}

# Set PARASA_DIR to the repo root so helpers.sh can find parasa.conf.
setup_parasa_dir() {
  PARASA_DIR="$SHELLSPEC_PROJECT_ROOT"
  export PARASA_DIR
}

# Create a temporary recipes tree for testing.
# Usage: setup_recipes_tree
# Sets RECIPES_TMP to the temp dir path.
setup_recipes_tree() {
  RECIPES_TMP="$SHELLSPEC_TMPDIR/recipes"
  mkdir -p "$RECIPES_TMP"
}

# Record commands instead of executing them.
# Usage: source this, then check $SHELLSPEC_TMPDIR/cmd_log
log_command() {
  echo "$*" >> "$SHELLSPEC_TMPDIR/cmd_log"
}
