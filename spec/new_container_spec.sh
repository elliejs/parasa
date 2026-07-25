# shellcheck shell=sh
# Tests for scripts/new_container.sh

Describe "new_container.sh"
  Describe "help and argument parsing"
    It "prints help with -h"
      When run script scripts/new_container.sh -h
      The status should be success
      The output should include "new_container"
      The output should include "Usage:"
    End

    It "rejects unknown flags"
      When run script scripts/new_container.sh -Z
      The status should be failure
      The error should include "Unknown option"
    End

    It "rejects unknown -o keys"
      When run script scripts/new_container.sh -s test -f base -o badkey=val -q
      The status should be failure
      The error should include "Unknown -o key"
    End

    It "requires root for actual execution"
      Mock id
        echo "1000"
      End
      When run script scripts/new_container.sh -s test -f base -q
      The status should be failure
      The error should include "root"
    End

    It "accepts all valid -o keys"
      Mock id
        echo "1000"
      End
      When run script scripts/new_container.sh -s x -f b -o home_dataset=no -o tmp_dataset=no -o user_homes=app -o mount_map=pool:mnt -q
      The status should be failure
      The error should include "root"
      # The point: it didn't die on any -o key
    End
  End

  # ── mount.fstab generation ─────────────────────────────────────────────
  # Replicate the mount.fstab generation logic from create_minhag_dir()
  # for isolated testing, same pattern as build_fstab_lines in new_system_spec.

  Describe "mount.fstab generation"
    Include scripts/helpers.sh

    # Replicated from new_container.sh create_minhag_dir() -- the printf
    # block that writes mount.fstab. Kept in sync manually.
    build_mount_fstab() {
      local data_root="zbamidbar/container-data/${CONTAINER_NAME}"
      local cpath="/containers/${CONTAINER_NAME}"
      MOUNT_FSTAB_LINES="# source	destination	fstype	options	dump	pass
${data_root}/var	${cpath}/var	zfs	rw	0	0
${data_root}/usr-local	${cpath}/usr/local	zfs	rw	0	0"
      if yesish "$WANT_HOME"; then
        MOUNT_FSTAB_LINES="${MOUNT_FSTAB_LINES}
${data_root}/home	${cpath}/home	zfs	rw	0	0"
      fi
      if yesish "$WANT_TMP"; then
        MOUNT_FSTAB_LINES="${MOUNT_FSTAB_LINES}
${data_root}/tmp	${cpath}/tmp	zfs	rw	0	0"
      fi
      if [ -n "$USER_HOMES" ]; then
        local old_ifs="$IFS" user
        IFS=','
        for user in $USER_HOMES; do
          IFS="$old_ifs"
          user=$(printf "%s" "$user" | tr -d '[:space:]')
          [ -n "$user" ] || continue
          MOUNT_FSTAB_LINES="${MOUNT_FSTAB_LINES}
${data_root}/home/${user}	${cpath}/home/${user}	zfs	rw	0	0"
        done
        IFS="$old_ifs"
      fi
      if [ -n "$CUSTOM_MOUNT_LINES" ]; then
        MOUNT_FSTAB_LINES="${MOUNT_FSTAB_LINES}
${CUSTOM_MOUNT_LINES}"
      fi
    }

    Describe "with all defaults (home=yes, tmp=yes)"
      setup_defaults() {
        CONTAINER_NAME="nginx"
        WANT_HOME="yes"
        WANT_TMP="yes"
        USER_HOMES=""
        CUSTOM_MOUNT_LINES=""
        MOUNT_FSTAB_LINES=""
      }
      Before 'setup_defaults'

      It "includes var and usr-local (always present)"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "container-data/nginx/var"
        The variable MOUNT_FSTAB_LINES should include "container-data/nginx/usr-local"
      End

      It "includes home and tmp when enabled"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "container-data/nginx/home"
        The variable MOUNT_FSTAB_LINES should include "container-data/nginx/tmp"
      End

      It "uses container path as destination prefix"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "/containers/nginx/var"
        The variable MOUNT_FSTAB_LINES should include "/containers/nginx/usr/local"
        The variable MOUNT_FSTAB_LINES should include "/containers/nginx/home"
        The variable MOUNT_FSTAB_LINES should include "/containers/nginx/tmp"
      End

      It "uses zfs fstype for data-lake mounts"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "zfs"
      End

      It "includes the header comment"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "# source"
      End
    End

    Describe "with home_dataset=no and tmp_dataset=no"
      setup_no_home_tmp() {
        CONTAINER_NAME="minimal"
        WANT_HOME="no"
        WANT_TMP="no"
        USER_HOMES=""
        CUSTOM_MOUNT_LINES=""
        MOUNT_FSTAB_LINES=""
      }
      Before 'setup_no_home_tmp'

      It "omits home and tmp mounts"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should not include "container-data/minimal/home"
        The variable MOUNT_FSTAB_LINES should not include "container-data/minimal/tmp"
      End

      It "still includes var and usr-local"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "container-data/minimal/var"
        The variable MOUNT_FSTAB_LINES should include "container-data/minimal/usr-local"
      End
    End

    Describe "with user_homes"
      setup_user_homes() {
        CONTAINER_NAME="devbox"
        WANT_HOME="yes"
        WANT_TMP="yes"
        USER_HOMES="app,deploy"
        CUSTOM_MOUNT_LINES=""
        MOUNT_FSTAB_LINES=""
      }
      Before 'setup_user_homes'

      It "adds per-user home mount entries"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "container-data/devbox/home/app"
        The variable MOUNT_FSTAB_LINES should include "/containers/devbox/home/app"
        The variable MOUNT_FSTAB_LINES should include "container-data/devbox/home/deploy"
        The variable MOUNT_FSTAB_LINES should include "/containers/devbox/home/deploy"
      End
    End

    Describe "with custom nullfs mounts"
      setup_custom() {
        CONTAINER_NAME="webapp"
        WANT_HOME="no"
        WANT_TMP="no"
        USER_HOMES=""
        CUSTOM_MOUNT_LINES="zbamidbar/shared-pool	/containers/webapp/shared	nullfs	rw	0	0"
        MOUNT_FSTAB_LINES=""
      }
      Before 'setup_custom'

      It "appends custom mount lines"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "zbamidbar/shared-pool"
        The variable MOUNT_FSTAB_LINES should include "/containers/webapp/shared"
        The variable MOUNT_FSTAB_LINES should include "nullfs"
      End
    End

    Describe "with shared dataset comment"
      setup_shared() {
        CONTAINER_NAME="frontend"
        WANT_HOME="no"
        WANT_TMP="no"
        USER_HOMES=""
        CUSTOM_MOUNT_LINES="zbamidbar/shared-cache	/containers/frontend/cache	nullfs	rw	0	0	# shared"
        MOUNT_FSTAB_LINES=""
      }
      Before 'setup_shared'

      It "preserves # shared comment in custom mounts"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "# shared"
      End
    End

    Describe "with everything enabled"
      setup_full() {
        CONTAINER_NAME="fullbox"
        WANT_HOME="yes"
        WANT_TMP="yes"
        USER_HOMES="alice,bob"
        CUSTOM_MOUNT_LINES="zbamidbar/ext	/containers/fullbox/ext	nullfs	rw	0	0"
        MOUNT_FSTAB_LINES=""
      }
      Before 'setup_full'

      It "includes all mount types"
        When call build_mount_fstab
        The variable MOUNT_FSTAB_LINES should include "/containers/fullbox/var"
        The variable MOUNT_FSTAB_LINES should include "/containers/fullbox/usr/local"
        The variable MOUNT_FSTAB_LINES should include "/containers/fullbox/home"
        The variable MOUNT_FSTAB_LINES should include "/containers/fullbox/tmp"
        The variable MOUNT_FSTAB_LINES should include "/containers/fullbox/home/alice"
        The variable MOUNT_FSTAB_LINES should include "/containers/fullbox/home/bob"
        The variable MOUNT_FSTAB_LINES should include "/containers/fullbox/ext"
      End

      count_mount_lines() {
        build_mount_fstab
        # Subtract 1 for the header comment line
        printf "%s\n" "$MOUNT_FSTAB_LINES" | wc -l | tr -d ' '
      }

      It "generates the correct number of lines"
        # header + var + usr-local + home + tmp + alice + bob + ext = 8
        When call count_mount_lines
        The output should equal "8"
      End
    End
  End

  # ── Full dry-run orchestration ─────────────────────────────────────────
  # Run the actual script as a subprocess with all external commands mocked.

  Describe "dry-run orchestration"
    Mock id
      printf "0\n"
    End

    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *foundation.zfs*)       exit 0 ;;
            *foundation.git*)       exit 0 ;;
            *containers*)      exit 1 ;;
            *buildspace*)            exit 1 ;;
            *container-data*)  exit 1 ;;
            *)                 exit 1 ;;
          esac
          ;;
        get)
          printf "no\n"
          ;;
        *) exit 0 ;;
      esac
    End

    Mock git
      case "$*" in
        *rev-parse*--abbrev-ref*) printf "stable/15\n" ;;
        *rev-parse*--short*)     printf "abc1234\n" ;;
        *config*remote.origin.url*) printf "/zbamidbar/foundation.git\n" ;;
        *) exit 0 ;;
      esac
    End

    Mock sysrc
      exit 1
    End

    Mock sysctl
      printf "4\n"
    End

    Mock sync
      exit 0
    End

    Mock chflags
      exit 0
    End

    setup_dry_container() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound"
      printf 'SRC_BRANCH=stable/15\n' > "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound/build.conf"
    }

    cleanup_dry_container() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound"
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/containers/dryjar"
    }

    Before 'setup_dry_container'
    After 'cleanup_dry_container'

    It "runs the full pipeline in dry-run mode"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The status should be success
      The error should include "[dry]"
      The error should include "dryjar"
    End

    It "reports the foundation name"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "testfound"
    End

    It "creates data datasets in dry-run output"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "Creating data datasets"
      The error should include "container-data/dryjar"
    End

    It "uses buildspace workspace for inaugural commit"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "zshemot/buildspace"
      The error should include "buildspace/dryjar"
    End

    It "creates the inaugural commit step"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "inaugural commit"
    End

    It "uses allow-empty for inaugural commit"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "allow-empty"
    End

    It "creates mount.fstab in minhag dir (not fstab.local)"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "mount.fstab"
      The error should not include "fstab.local"
    End

    It "creates jail.conf in minhag dir"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "jail.conf"
    End

    It "respects -o home_dataset=no"
      When run script scripts/new_container.sh -s dryjar -f testfound -o home_dataset=no -q -d
      The status should be success
      The error should include "home:        no"
    End

    It "respects -o user_homes"
      When run script scripts/new_container.sh -s dryjar -f testfound -o user_homes=app,worker -q -d
      The status should be success
      The error should include "app"
      The error should include "worker"
    End

    It "destroys the transient workspace"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "Destroying workspace"
    End

    It "shows success message at end"
      When run script scripts/new_container.sh -s dryjar -f testfound -q -d
      The error should include "created successfully"
    End

    It "suppresses progress with -qq"
      When run script scripts/new_container.sh -s dryjar -f testfound -qq -d
      The status should be success
      The error should include "[dry]"
      The error should not include "==>"
    End
  End

  # ── Minhag dir file creation ──────────────────────────────────────────
  # Non-dry-run: verify the actual files created in the minhag dir.
  # We mock all ZFS/git commands but let filesystem operations run real.

  Describe "minhag dir contents"
    Mock id
      printf "0\n"
    End

    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *foundation.zfs*)       exit 0 ;;
            *foundation.git*)       exit 0 ;;
            *containers*)      exit 1 ;;
            *buildspace*)            exit 1 ;;
            *container-data*)  exit 1 ;;
            *)                 exit 1 ;;
          esac
          ;;
        get)
          printf "no\n"
          ;;
        *) exit 0 ;;
      esac
    End

    Mock git
      case "$*" in
        *rev-parse*--abbrev-ref*) printf "stable/15\n" ;;
        *rev-parse*--short*)     printf "abc1234\n" ;;
        *config*remote.origin.url*) printf "/zbamidbar/foundation.git\n" ;;
        *) exit 0 ;;
      esac
    End

    Mock sysrc
      exit 1
    End

    Mock sysctl
      printf "4\n"
    End

    Mock sync
      exit 0
    End

    Mock chflags
      exit 0
    End

    setup_minhag_test() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/base15"
      printf 'SRC_BRANCH=stable/15\n' > "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/base15/build.conf"
    }

    cleanup_minhag_test() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/base15"
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/containers/filetest"
    }

    Before 'setup_minhag_test'
    After 'cleanup_minhag_test'

    # Run dry-run so create_minhag_dir writes files but ZFS/git are mocked
    # Note: create_minhag_dir writes real files even outside dry-run,
    # but the script uses dry-run for ZFS/git. We use -d to skip those
    # but create_minhag_dir's file creation is behind !$DRY_RUN.
    # So we test via dry-run output which lists the files.

    It "lists mount.fstab in dry-run file creation"
      When run script scripts/new_container.sh -s filetest -f base15 -q -d
      The status should be success
      The error should include "mount.fstab"
    End

    It "lists jail.conf in dry-run file creation"
      When run script scripts/new_container.sh -s filetest -f base15 -q -d
      The status should be success
      The error should include "jail.conf"
    End

    It "does not create or mention fstab.local"
      When run script scripts/new_container.sh -s filetest -f base15 -q -d
      The status should be success
      The error should not include "fstab.local"
    End
  End

  # ── Name collision detection ──────────────────────────────────────────

  Describe "name collision detection"
    Mock id
      printf "0\n"
    End

    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *foundation.zfs*)     exit 0 ;;
            *containers*)    exit 0 ;;
            *)               exit 1 ;;
          esac
          ;;
        *) exit 0 ;;
      esac
    End

    Mock sysrc
      exit 1
    End

    Mock sysctl
      printf "4\n"
    End

    Mock git
      exit 0
    End

    Mock sync
      exit 0
    End

    setup_collision() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound"
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/minhag/containers/taken"
    }

    cleanup_collision() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound"
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/containers/taken"
    }

    Before 'setup_collision'
    After 'cleanup_collision'

    It "rejects a container name that already exists in minhag"
      When run script scripts/new_container.sh -s taken -f testfound -q -d
      The status should be failure
      The error should include "already exists"
    End

    It "rejects a container name already deployed on zbereshit"
      When run script scripts/new_container.sh -s deployed -f testfound -q -d
      The status should be failure
      The error should include "already deployed"
    End
  End
End
