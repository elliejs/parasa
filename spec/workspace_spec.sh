# shellcheck shell=sh
# Tests for scripts/workspace.sh -- shared workspace functions.

Describe "workspace.sh"
  Include scripts/helpers.sh
  Include scripts/workspace.sh

  # ── run() ──────────────────────────────────────────────────────────────

  Describe "run()"
    It "prints [dry] prefix when DRY_RUN is true"
      DRY_RUN=true
      When call run echo hello
      The error should include "[dry]"
      The error should include "echo hello"
      The output should equal ""
    End

    It "executes the command when DRY_RUN is false"
      DRY_RUN=false
      When call run echo hello
      The output should equal "hello"
    End
  End

  # ── progress() ─────────────────────────────────────────────────────────

  Describe "progress()"
    It "prints ==> header when QUIET is 0"
      QUIET=0
      When call progress "Building"
      The error should include "==> Building"
    End

    It "prints ==> header when QUIET is 1"
      QUIET=1
      When call progress "Building"
      The error should include "==> Building"
    End

    It "suppresses output when QUIET is 2"
      QUIET=2
      When call progress "Building"
      The error should equal ""
    End
  End

  # ── collect_name() ─────────────────────────────────────────────────────
  # collect_name calls die/exit on failure, so wrap in a subshell
  # to prevent aborting the test process.

  Describe "collect_name()"
    # Subshell wrapper — contains exit so ShellSpec can capture status
    try_collect_name() { (collect_name "$@"); }

    Describe "with a pre-set name"
      It "returns a valid name unchanged"
        QUIET=0
        When call try_collect_name "mybox" "System"
        The output should equal "mybox"
        The status should be success
      End

      It "accepts names with dots and underscores"
        QUIET=0
        When call try_collect_name "generic_stable15.0" "Container"
        The output should equal "generic_stable15.0"
        The status should be success
      End

      It "rejects names with spaces"
        QUIET=0
        When call try_collect_name "my box" "System"
        The status should be failure
        The error should include "may only contain"
      End

      It "rejects names with slashes"
        QUIET=0
        When call try_collect_name "my/box" "Container"
        The status should be failure
        The error should include "may only contain"
      End

      It "rejects empty names in quiet mode"
        QUIET=1
        When call try_collect_name "" "System"
        The status should be failure
        The error should include "required in quiet mode"
      End

      It "rejects names starting with a hyphen"
        QUIET=0
        When call try_collect_name "-badname" "System"
        The status should be failure
        The error should include "cannot start with a hyphen"
      End
    End
  End

  # ── check_available() ──────────────────────────────────────────────────
  # check_available calls die on collision, so wrap in a subshell.

  Describe "check_available()"
    try_check_available() { (check_available); }

    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *zbereshit/systems/taken*)     exit 0 ;;
            *zbereshit/containers/taken*)  exit 0 ;;
            *) exit 1 ;;
          esac
          ;;
        *) exit 0 ;;
      esac
    End

    Describe "for systems"
      setup_system_check() {
        WS_KIND="system"
        WS_NAME="fresh"
        PARASA_DIR="$SHELLSPEC_TMPDIR/parasa"
        rm -rf "$PARASA_DIR/recipes/systems"
        mkdir -p "$PARASA_DIR/recipes/systems"
      }
      Before 'setup_system_check'

      It "succeeds when no collision exists"
        When call try_check_available
        The status should be success
      End

      It "dies when recipes dir exists"
        mkdir -p "$PARASA_DIR/recipes/systems/fresh"
        When call try_check_available
        The status should be failure
        The error should include "already exists"
        The error should include "System"
      End

      It "dies when zbereshit dataset exists"
        WS_NAME="taken"
        When call try_check_available
        The status should be failure
        The error should include "already deployed"
        The error should include "System"
      End
    End

    Describe "for containers"
      setup_container_check() {
        WS_KIND="container"
        WS_NAME="fresh"
        PARASA_DIR="$SHELLSPEC_TMPDIR/parasa"
        rm -rf "$PARASA_DIR/recipes/containers"
        mkdir -p "$PARASA_DIR/recipes/containers"
      }
      Before 'setup_container_check'

      It "succeeds when no collision exists"
        When call try_check_available
        The status should be success
      End

      It "dies when recipes dir exists"
        mkdir -p "$PARASA_DIR/recipes/containers/fresh"
        When call try_check_available
        The status should be failure
        The error should include "already exists"
        The error should include "Container"
      End

      It "dies when zbereshit dataset exists"
        WS_NAME="taken"
        When call try_check_available
        The status should be failure
        The error should include "already deployed"
        The error should include "Container"
      End
    End
  End

  # ── collect_foundation() ───────────────────────────────────────────────
  # collect_foundation calls die on failure, so wrap in a subshell.

  Describe "collect_foundation()"
    try_collect_foundation() { (collect_foundation); }

    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *foundation.zfs*base15*) exit 0 ;;
            *)                  exit 1 ;;
          esac
          ;;
        *) exit 0 ;;
      esac
    End

    setup_foundation() {
      PARASA_DIR="$SHELLSPEC_TMPDIR/parasa"
      mkdir -p "$PARASA_DIR/recipes/foundations/base15"
      QUIET=1
    }
    Before 'setup_foundation'

    It "accepts a valid foundation"
      FOUNDATION_NAME="base15"
      When call try_collect_foundation
      The status should be success
    End

    It "rejects a foundation not in recipes"
      FOUNDATION_NAME="nonexistent"
      When call try_collect_foundation
      The status should be failure
      The error should include "not found"
    End

    It "rejects a foundation not archived in foundation.zfs"
      mkdir -p "$PARASA_DIR/recipes/foundations/unarchived"
      FOUNDATION_NAME="unarchived"
      When call try_collect_foundation
      The status should be failure
      The error should include "not archived"
    End
  End

  # ── collect_build_options() ────────────────────────────────────────────

  Describe "collect_build_options()"
    Describe "in quiet mode with defaults"
      setup_defaults() {
        QUIET=1
        OPT_HOME="yes"
        OPT_TMP="yes"
        OPT_USER_HOMES=""
        OPT_MOUNT_MAP=""
      }
      Before 'setup_defaults'

      It "sets WANT_HOME and WANT_TMP to yes"
        When call collect_build_options
        The variable WANT_HOME should equal "yes"
        The variable WANT_TMP should equal "yes"
      End

      It "sets USER_HOMES and CUSTOM_MOUNTS to empty"
        When call collect_build_options
        The variable USER_HOMES should equal ""
        The variable CUSTOM_MOUNTS should equal ""
      End
    End

    Describe "in quiet mode with overrides"
      setup_overrides() {
        QUIET=1
        OPT_HOME="no"
        OPT_TMP="no"
        OPT_USER_HOMES="alice,bob"
        OPT_MOUNT_MAP="zbamidbar/pool:/shared"
      }
      Before 'setup_overrides'

      It "respects OPT_HOME=no"
        When call collect_build_options
        The variable WANT_HOME should equal "no"
      End

      It "respects OPT_TMP=no"
        When call collect_build_options
        The variable WANT_TMP should equal "no"
      End

      It "passes through OPT_USER_HOMES"
        When call collect_build_options
        The variable USER_HOMES should equal "alice,bob"
      End

      It "passes through OPT_MOUNT_MAP"
        When call collect_build_options
        The variable CUSTOM_MOUNTS should equal "zbamidbar/pool:/shared"
      End
    End
  End

  # ── create_recipe_boilerplate() ────────────────────────────────────────

  Describe "create_recipe_boilerplate()"
    Describe "creates the five standard files"
      setup_boilerplate() {
        DRY_RUN=false
        QUIET=2
        WS_NAME="testws"
        WS_KIND="system"
        FOUNDATION_NAME="stable15"
        PARASA_DIR="$SHELLSPEC_TMPDIR/parasa"
        mkdir -p "$PARASA_DIR/recipes/systems"
      }

      cleanup_boilerplate() {
        rm -rf "$SHELLSPEC_TMPDIR/parasa/recipes/systems/testws"
      }

      Before 'setup_boilerplate'
      After 'cleanup_boilerplate'

      It "creates the recipes directory"
        When call create_recipe_boilerplate
        The path "$SHELLSPEC_TMPDIR/parasa/recipes/systems/testws" should be directory
      End

      It "creates the .foundation file"
        When call create_recipe_boilerplate
        The path "$SHELLSPEC_TMPDIR/parasa/recipes/systems/testws/stable15.foundation" should be file
      End

      It "creates compose.sh"
        When call create_recipe_boilerplate
        The path "$SHELLSPEC_TMPDIR/parasa/recipes/systems/testws/compose.sh" should be file
      End

      It "creates derivations.local"
        When call create_recipe_boilerplate
        The path "$SHELLSPEC_TMPDIR/parasa/recipes/systems/testws/derivations.local" should be file
      End

      It "creates pkg.list"
        When call create_recipe_boilerplate
        The path "$SHELLSPEC_TMPDIR/parasa/recipes/systems/testws/pkg.list" should be file
      End

      It "creates mtree.dist"
        When call create_recipe_boilerplate
        The path "$SHELLSPEC_TMPDIR/parasa/recipes/systems/testws/mtree.dist" should be file
      End

      It "sets WS_RECIPE_DIR correctly"
        When call create_recipe_boilerplate
        The variable WS_RECIPE_DIR should equal "$SHELLSPEC_TMPDIR/parasa/recipes/systems/testws"
      End
    End

    Describe "for containers"
      setup_container_bp() {
        DRY_RUN=false
        QUIET=2
        WS_NAME="nginx"
        WS_KIND="container"
        FOUNDATION_NAME="base15"
        PARASA_DIR="$SHELLSPEC_TMPDIR/parasa"
        mkdir -p "$PARASA_DIR/recipes/containers"
      }

      cleanup_container_bp() {
        rm -rf "$SHELLSPEC_TMPDIR/parasa/recipes/containers/nginx"
      }

      Before 'setup_container_bp'
      After 'cleanup_container_bp'

      It "uses containers/ subdir when WS_KIND is container"
        When call create_recipe_boilerplate
        The path "$SHELLSPEC_TMPDIR/parasa/recipes/containers/nginx" should be directory
        The variable WS_RECIPE_DIR should include "containers/nginx"
      End
    End

    Describe "in dry-run mode"
      setup_dry_bp() {
        DRY_RUN=true
        QUIET=0
        WS_NAME="drybox"
        WS_KIND="system"
        FOUNDATION_NAME="stable15"
        PARASA_DIR="$SHELLSPEC_TMPDIR/parasa"
        mkdir -p "$PARASA_DIR/recipes/systems"
      }
      Before 'setup_dry_bp'

      It "prints [dry] and does not create files"
        When call create_recipe_boilerplate
        The error should include "[dry]"
        The error should include "stable15.foundation"
        The error should include "compose.sh"
        The path "$SHELLSPEC_TMPDIR/parasa/recipes/systems/drybox" should not be exist
      End
    End
  End

  # ── create_data_datasets() dry-run ─────────────────────────────────────

  Describe "create_data_datasets()"
    Mock zfs
      exit 0
    End

    Mock sync
      exit 0
    End

    Describe "dry-run with all defaults"
      setup_datasets() {
        DRY_RUN=true
        QUIET=2
        WS_NAME="srv"
        WS_DATA_POOL="system-data"
        FOUNDATION_NAME="base15"
        WANT_HOME="yes"
        WANT_TMP="yes"
        USER_HOMES=""
      }
      Before 'setup_datasets'

      It "sets WS_DATA_ROOT and mentions parent dataset"
        When call create_data_datasets
        The variable WS_DATA_ROOT should equal "zbamidbar/system-data/srv"
        The error should include "system-data/srv"
      End

      It "mentions var copy from foundation"
        When call create_data_datasets
        The error should include "foundation.zfs/base15/var"
      End

      It "mentions usr-local"
        When call create_data_datasets
        The error should include "system-data/srv/usr-local"
      End

      It "mentions home when enabled"
        When call create_data_datasets
        The error should include "system-data/srv/home"
      End

      It "mentions tmp when enabled"
        When call create_data_datasets
        The error should include "system-data/srv/tmp"
      End
    End

    Describe "dry-run with home and tmp disabled"
      setup_no_optional() {
        DRY_RUN=true
        QUIET=2
        WS_NAME="minimal"
        WS_DATA_POOL="container-data"
        FOUNDATION_NAME="base15"
        WANT_HOME="no"
        WANT_TMP="no"
        USER_HOMES=""
      }
      Before 'setup_no_optional'

      It "omits home when disabled"
        When call create_data_datasets
        The error should not include "container-data/minimal/home"
      End

      It "omits tmp when disabled"
        When call create_data_datasets
        The error should not include "container-data/minimal/tmp"
      End

      It "still creates parent and usr-local"
        When call create_data_datasets
        The error should include "container-data/minimal"
        The error should include "container-data/minimal/usr-local"
      End
    End

    Describe "dry-run with WANT_ROOTHOME"
      setup_roothome() {
        DRY_RUN=true
        QUIET=2
        WS_NAME="rootbox"
        WS_DATA_POOL="system-data"
        FOUNDATION_NAME="base15"
        WANT_HOME="yes"
        WANT_TMP="yes"
        WANT_ROOTHOME="yes"
        USER_HOMES=""
      }
      Before 'setup_roothome'

      It "creates home/root when WANT_ROOTHOME is yes"
        When call create_data_datasets
        The error should include "system-data/rootbox/home/root"
      End
    End

    Describe "dry-run without WANT_ROOTHOME set (container case)"
      setup_no_roothome() {
        DRY_RUN=true
        QUIET=2
        WS_NAME="jail1"
        WS_DATA_POOL="container-data"
        FOUNDATION_NAME="base15"
        WANT_HOME="yes"
        WANT_TMP="yes"
        USER_HOMES=""
        # WANT_ROOTHOME intentionally not set -- ${WANT_ROOTHOME:-no} fallback
        unset WANT_ROOTHOME 2>/dev/null || true
      }
      Before 'setup_no_roothome'

      It "skips home/root when WANT_ROOTHOME is unset"
        When call create_data_datasets
        The error should not include "home/root"
      End
    End

    Describe "dry-run with user homes"
      setup_user_homes() {
        DRY_RUN=true
        QUIET=2
        WS_NAME="devbox"
        WS_DATA_POOL="system-data"
        FOUNDATION_NAME="base15"
        WANT_HOME="yes"
        WANT_TMP="yes"
        USER_HOMES="alice,bob"
      }
      Before 'setup_user_homes'

      It "creates per-user home datasets"
        When call create_data_datasets
        The error should include "system-data/devbox/home/alice"
        The error should include "system-data/devbox/home/bob"
      End
    End
  End

  # ── ws_commit() ────────────────────────────────────────────────────────

  Describe "ws_commit()"
    Mock git
      exit 0
    End

    Describe "without extra args (system case)"
      setup_commit() {
        DRY_RUN=true
        QUIET=2
        WS_NAME="wonderland"
        WS_KIND="system"
        WS_PATH="/zshemot/buildspace/wonderland"
      }
      Before 'setup_commit'

      It "commits with kind/name inaugural message"
        When call ws_commit
        The error should include "commit"
        The error should include "systems/wonderland inaugural"
      End

      It "pushes the branch"
        When call ws_commit
        The error should include "push origin systems/wonderland"
      End
    End

    Describe "with --allow-empty (container case)"
      setup_commit_empty() {
        DRY_RUN=true
        QUIET=2
        WS_NAME="nginx"
        WS_KIND="container"
        WS_PATH="/zshemot/buildspace/nginx"
      }
      Before 'setup_commit_empty'

      It "passes --allow-empty to git commit"
        When call ws_commit --allow-empty
        The error should include "allow-empty"
        The error should include "containers/nginx inaugural"
      End

      It "pushes the container branch"
        When call ws_commit --allow-empty
        The error should include "push origin containers/nginx"
      End
    End
  End

  # ── ws_begin() dry-run ─────────────────────────────────────────────────

  Describe "ws_begin()"
    Mock zfs
      case "$1" in
        list) exit 1 ;;
        *)    exit 0 ;;
      esac
    End

    Mock git
      case "$*" in
        *config*remote.origin.url*) printf "/zbamidbar/foundation.git\n" ;;
        *) exit 0 ;;
      esac
    End

    Mock sync
      exit 0
    End

    setup_begin() {
      DRY_RUN=true
      QUIET=0
      WS_NAME="testbox"
      WS_KIND="system"
      FOUNDATION_NAME="base15"
    }
    Before 'setup_begin'

    It "sets WS_PATH and shows progress"
      When call ws_begin
      The variable WS_PATH should equal "/zshemot/buildspace/testbox"
      The error should include "Creating inaugural commit"
    End

    It "mounts foundation.git and foundation.zfs"
      When call ws_begin
      The error should include "foundation.git"
      The error should include "foundation.zfs"
    End

    It "ensures buildspace parent exists"
      When call ws_begin
      The error should include "zshemot/buildspace"
    End

    It "recvs foundation to buildspace"
      When call ws_begin
      The error should include "zfs send -R"
      The error should include "buildspace/testbox"
    End

    It "creates the correct branch"
      When call ws_begin
      The error should include "checkout -b systems/testbox base15"
    End

    It "shows workspace receiving progress"
      When call ws_begin
      The error should include "Receiving foundation to workspace"
    End
  End

  Describe "ws_begin() for container kind"
    Mock zfs
      case "$1" in
        list) exit 1 ;;
        *)    exit 0 ;;
      esac
    End

    Mock git
      exit 0
    End

    Mock sync
      exit 0
    End

    setup_container_begin() {
      DRY_RUN=true
      QUIET=0
      WS_NAME="webjar"
      WS_KIND="container"
      FOUNDATION_NAME="stable15"
    }
    Before 'setup_container_begin'

    It "creates container branch"
      When call ws_begin
      The error should include "checkout -b containers/webjar stable15"
    End

    It "shows container branch setup progress"
      When call ws_begin
      The error should include "Setting up container branch"
    End
  End

  # ── ws_end() dry-run ───────────────────────────────────────────────────

  Describe "ws_end()"
    Mock zfs
      case "$1" in
        list) exit 1 ;;
        *)    exit 0 ;;
      esac
    End

    Mock sync
      exit 0
    End

    Mock chflags
      exit 0
    End

    setup_end() {
      DRY_RUN=true
      QUIET=0
      WS_NAME="testbox"
      WS_PATH="/zshemot/buildspace/testbox"
    }
    Before 'setup_end'

    It "shows destroying workspace progress"
      When call ws_end
      The error should include "Destroying workspace"
    End

    It "unmounts foundation.git"
      When call ws_end
      The error should include "zunmount zbamidbar/foundation.git"
    End

    It "unmounts foundation.zfs"
      When call ws_end
      The error should include "zunmount zbamidbar/foundation.zfs"
    End
  End

  # ── ws_cleanup() ───────────────────────────────────────────────────────

  Describe "ws_cleanup()"
    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *buildspace/active*) exit 0 ;;
            *)             exit 1 ;;
          esac
          ;;
        destroy) exit 0 ;;
        *) exit 0 ;;
      esac
    End

    It "cleans up when WS_NAME is set and workspace exists"
      WS_NAME="active"
      When call ws_cleanup
      The error should include "Cleaning up"
      The error should include "zshemot/buildspace/active"
    End

    It "does nothing when WS_NAME is empty"
      WS_NAME=""
      When call ws_cleanup
      The error should equal ""
    End

    It "does nothing when workspace does not exist"
      WS_NAME="nonexistent"
      When call ws_cleanup
      The error should equal ""
    End
  End
End
