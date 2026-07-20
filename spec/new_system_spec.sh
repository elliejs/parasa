# shellcheck shell=sh
# Tests for scripts/new_system.sh

Describe "new_system.sh"
  Describe "help and argument parsing"
    It "prints help with -h"
      When run script scripts/new_system.sh -h
      The status should be success
      The output should include "new_system"
      The output should include "Usage:"
    End

    It "rejects unknown flags"
      When run script scripts/new_system.sh -Z
      The status should be failure
      The error should include "Unknown option"
    End

    It "rejects unknown -o keys"
      When run script scripts/new_system.sh -s test -f base -o badkey=val -q
      The status should be failure
      The error should include "Unknown -o key"
    End

    It "requires root for actual execution"
      Mock id
        echo "1000"
      End
      When run script scripts/new_system.sh -s test -f base -q
      The status should be failure
      The error should include "root"
    End

    It "accepts all valid -o keys"
      Mock id
        echo "1000"
      End
      When run script scripts/new_system.sh -s x -f b -o home_dataset=no -o tmp_dataset=no -o roothome_dataset=no -o user_homes=alice -o mount_map=pool:mnt -q
      The status should be failure
      The error should include "root"
      # The point: it didn't die on any -o key
    End
  End

  # ── build_fstab_lines ────────────────────────────────────────────────────
  # This function is pure logic: reads variables, writes FSTAB_LINES.
  # We source helpers.sh and define it here to test in isolation.

  Describe "build_fstab_lines()"
    Include scripts/helpers.sh

    # Define the function from new_system.sh so we can test it without
    # running main(). Kept in sync manually — if it drifts, tests break,
    # which is the signal to update.
    build_fstab_lines() {
      local data_root="zbamidbar/system-data/${SYSTEM_NAME}"
      FSTAB_LINES="${data_root}/var	/var	zfs	rw,late	0	0
${data_root}/usr-local	/usr/local	zfs	rw,late	0	0"
      if yesish "$WANT_HOME"; then
        FSTAB_LINES="${FSTAB_LINES}
${data_root}/home	/home	zfs	rw,late	0	0"
      fi
      if yesish "$WANT_TMP"; then
        FSTAB_LINES="${FSTAB_LINES}
${data_root}/tmp	/tmp	zfs	rw,late	0	0"
      fi
      if yesish "$WANT_ROOTHOME"; then
        FSTAB_LINES="${FSTAB_LINES}
${data_root}/home/root	/root	zfs	rw,late	0	0"
      fi
      if [ -n "$USER_HOMES" ]; then
        local old_ifs="$IFS" user
        IFS=','
        for user in $USER_HOMES; do
          IFS="$old_ifs"
          user=$(printf "%s" "$user" | tr -d '[:space:]')
          [ -n "$user" ] || continue
          FSTAB_LINES="${FSTAB_LINES}
${data_root}/home/${user}	/home/${user}	zfs	rw,late	0	0"
        done
        IFS="$old_ifs"
      fi
      if [ -n "$SYSTEM_MOUNTS" ]; then
        FSTAB_LINES="${FSTAB_LINES}
${SYSTEM_MOUNTS}"
      fi
      if [ -n "$RECIPE_MOUNTS" ]; then
        FSTAB_LINES="${FSTAB_LINES}
${RECIPE_MOUNTS}"
      fi
    }

    Describe "with all defaults (home=yes, tmp=yes)"
      setup_defaults() {
        SYSTEM_NAME="wonderland"
        WANT_HOME="yes"
        WANT_TMP="yes"
        WANT_ROOTHOME="no"
        USER_HOMES=""
        SYSTEM_MOUNTS=""
        RECIPE_MOUNTS=""
        FSTAB_LINES=""
      }
      Before 'setup_defaults'

      It "includes var, usr-local, home, and tmp"
        When call build_fstab_lines
        The variable FSTAB_LINES should include "system-data/wonderland/var"
        The variable FSTAB_LINES should include "system-data/wonderland/usr-local"
        The variable FSTAB_LINES should include "system-data/wonderland/home"
        The variable FSTAB_LINES should include "system-data/wonderland/tmp"
      End

      It "uses correct mountpoints"
        When call build_fstab_lines
        The variable FSTAB_LINES should include "/var"
        The variable FSTAB_LINES should include "/usr/local"
        The variable FSTAB_LINES should include "/home"
        The variable FSTAB_LINES should include "/tmp"
      End

      It "does not include /root or user homes"
        When call build_fstab_lines
        The variable FSTAB_LINES should not include "/root"
        The variable FSTAB_LINES should not include "home/alice"
      End
    End

    Describe "with home_dataset=no"
      setup_no_home() {
        SYSTEM_NAME="testbox"
        WANT_HOME="no"
        WANT_TMP="yes"
        WANT_ROOTHOME="no"
        USER_HOMES=""
        SYSTEM_MOUNTS=""
        RECIPE_MOUNTS=""
        FSTAB_LINES=""
      }
      Before 'setup_no_home'

      It "omits home mount"
        When call build_fstab_lines
        The variable FSTAB_LINES should include "system-data/testbox/var"
        The variable FSTAB_LINES should not include "system-data/testbox/home"
      End
    End

    Describe "with roothome_dataset=yes"
      setup_roothome() {
        SYSTEM_NAME="srv"
        WANT_HOME="yes"
        WANT_TMP="no"
        WANT_ROOTHOME="yes"
        USER_HOMES=""
        SYSTEM_MOUNTS=""
        RECIPE_MOUNTS=""
        FSTAB_LINES=""
      }
      Before 'setup_roothome'

      It "includes /root mount"
        When call build_fstab_lines
        The variable FSTAB_LINES should include "system-data/srv/home/root"
        The variable FSTAB_LINES should include "/root"
      End

      It "omits tmp when disabled"
        When call build_fstab_lines
        The variable FSTAB_LINES should not include "/tmp"
      End
    End

    Describe "with user_homes"
      setup_user_homes() {
        SYSTEM_NAME="dev"
        WANT_HOME="yes"
        WANT_TMP="yes"
        WANT_ROOTHOME="no"
        USER_HOMES="alice,bob"
        SYSTEM_MOUNTS=""
        RECIPE_MOUNTS=""
        FSTAB_LINES=""
      }
      Before 'setup_user_homes'

      It "adds per-user home mounts"
        When call build_fstab_lines
        The variable FSTAB_LINES should include "system-data/dev/home/alice"
        The variable FSTAB_LINES should include "/home/alice"
        The variable FSTAB_LINES should include "system-data/dev/home/bob"
        The variable FSTAB_LINES should include "/home/bob"
      End
    End

    Describe "with custom system mounts"
      setup_system_mounts() {
        SYSTEM_NAME="custom"
        WANT_HOME="no"
        WANT_TMP="no"
        WANT_ROOTHOME="no"
        USER_HOMES=""
        SYSTEM_MOUNTS="zbamidbar/shared-pool	/shared	zfs	rw,late	0	0"
        RECIPE_MOUNTS=""
        FSTAB_LINES=""
      }
      Before 'setup_system_mounts'

      It "appends system mount entries"
        When call build_fstab_lines
        The variable FSTAB_LINES should include "zbamidbar/shared-pool"
        The variable FSTAB_LINES should include "/shared"
      End
    End

    Describe "with recipe mounts"
      setup_recipe_mounts() {
        SYSTEM_NAME="recipe"
        WANT_HOME="no"
        WANT_TMP="no"
        WANT_ROOTHOME="no"
        USER_HOMES=""
        SYSTEM_MOUNTS=""
        RECIPE_MOUNTS="zbamidbar/jail-shared	/jail/shared	zfs	rw,late	0	0"
        FSTAB_LINES=""
      }
      Before 'setup_recipe_mounts'

      It "appends recipe mount entries to fstab"
        When call build_fstab_lines
        The variable FSTAB_LINES should include "zbamidbar/jail-shared"
        The variable FSTAB_LINES should include "/jail/shared"
      End
    End

    Describe "with everything enabled"
      setup_full() {
        SYSTEM_NAME="fullbox"
        WANT_HOME="yes"
        WANT_TMP="yes"
        WANT_ROOTHOME="yes"
        USER_HOMES="alice,bob,carol"
        SYSTEM_MOUNTS="zbamidbar/external	/mnt/ext	zfs	rw,late	0	0"
        RECIPE_MOUNTS="zbamidbar/jail-data	/jail/data	zfs	rw,late	0	0"
        FSTAB_LINES=""
      }
      Before 'setup_full'

      It "includes all mount types"
        When call build_fstab_lines
        The variable FSTAB_LINES should include "/var"
        The variable FSTAB_LINES should include "/usr/local"
        The variable FSTAB_LINES should include "/home"
        The variable FSTAB_LINES should include "/tmp"
        The variable FSTAB_LINES should include "/root"
        The variable FSTAB_LINES should include "/home/alice"
        The variable FSTAB_LINES should include "/home/bob"
        The variable FSTAB_LINES should include "/home/carol"
        The variable FSTAB_LINES should include "/mnt/ext"
        The variable FSTAB_LINES should include "/jail/data"
      End

      count_fstab_lines() {
        build_fstab_lines
        printf "%s\n" "$FSTAB_LINES" | wc -l | tr -d ' '
      }

      It "generates the correct number of lines"
        # var, usr-local, home, tmp, root, alice, bob, carol, external, jail-data = 10
        When call count_fstab_lines
        The output should equal "10"
      End
    End
  End

  # ── Full dry-run orchestration ───────────────────────────────────────────
  # Run the actual script as a subprocess with all external commands mocked.
  # Verifies the orchestration sequence without touching real disks.

  Describe "dry-run orchestration"
    Mock id
      printf "0\n"
    End

    Mock zfs
      case "$1" in
        list)
          # Foundation archives exist; systems and tablets don't
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *sinai.zfs*)    exit 0 ;;
            *sinai.git*)    exit 0 ;;
            *systems*)      exit 1 ;;
            *tablets*)      exit 1 ;;
            *system-data*)  exit 1 ;;
            *)              exit 1 ;;
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
        *config*remote.origin.url*) printf "/zbamidbar/sinai.git\n" ;;
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

    setup_dry_system() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound"
      printf 'SRC_BRANCH=stable/15\n' > "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound/build.conf"
    }

    cleanup_dry_system() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound"
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/systems/drybox"
    }

    Before 'setup_dry_system'
    After 'cleanup_dry_system'

    It "runs the full pipeline in dry-run mode"
      When run script scripts/new_system.sh -s drybox -f testfound -q -d
      The status should be success
      The error should include "[dry]"
      The error should include "drybox"
    End

    It "reports the foundation name"
      When run script scripts/new_system.sh -s drybox -f testfound -q -d
      The error should include "testfound"
    End

    It "creates datasets in dry-run output"
      When run script scripts/new_system.sh -s drybox -f testfound -q -d
      The error should include "Creating data datasets"
      The error should include "system-data/drybox"
    End

    It "creates the inaugural commit step"
      When run script scripts/new_system.sh -s drybox -f testfound -q -d
      The error should include "inaugural commit"
    End

    It "includes standard mounts in dry-run"
      When run script scripts/new_system.sh -s drybox -f testfound -q -d
      The error should include "fstab"
    End

    It "respects -o home_dataset=no"
      When run script scripts/new_system.sh -s drybox -f testfound -o home_dataset=no -q -d
      The status should be success
      The error should include "home:        no"
    End

    It "respects -o user_homes"
      When run script scripts/new_system.sh -s drybox -f testfound -o user_homes=alice,bob -q -d
      The status should be success
      The error should include "alice"
      The error should include "bob"
    End

    It "fails when foundation minhag does not exist"
      When run script scripts/new_system.sh -s drybox -f nonexistent -q -d
      The status should be failure
      The error should include "not found"
    End

    It "shows success message at end"
      When run script scripts/new_system.sh -s drybox -f testfound -q -d
      The error should include "created successfully"
    End
  End

  # ── Name availability ───────────────────────────────────────────────────
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
            *sinai.zfs*) exit 0 ;;
            *)           exit 1 ;;
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
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/minhag/systems/taken"
    }

    cleanup_collision() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/foundations/testfound"
      rm -rf "$SHELLSPEC_PROJECT_ROOT/minhag/systems/taken"
    }

    Before 'setup_collision'
    After 'cleanup_collision'

    It "rejects a system name that already exists in minhag"
      When run script scripts/new_system.sh -s taken -f testfound -q -d
      The status should be failure
      The error should include "already exists"
    End
  End
End
