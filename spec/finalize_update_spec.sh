# shellcheck shell=sh
# Tests for scripts/finalize_update.sh

Describe "finalize_update.sh"
  Describe "help and argument parsing"
    It "prints help with -h"
      When run script scripts/finalize_update.sh -h
      The status should be success
      The output should include "finalize_update"
      The output should include "Usage:"
    End

    It "rejects unknown flags"
      When run script scripts/finalize_update.sh -Z
      The status should be failure
      The error should include "Unknown option"
    End

    It "requires -s NAME"
      When run script scripts/finalize_update.sh -d
      The status should be failure
      The error should include "name required"
    End
  End

  Describe "dry-run mode"
    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *-new|*foundations*) exit 0 ;;
            *systems*)          exit 0 ;;
            *)                  exit 1 ;;
          esac
          ;;
        get) printf "no\n" ;;
        *) exit 0 ;;
      esac
    End

    Mock sync
      exit 0
    End

    Mock jail
      exit 0
    End

    setup_finalize_dry() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/systems/finbox"
      printf "stable-15_2026-07-01_def5678\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/finbox/15-stable-generic.foundation"
    }

    cleanup_finalize_dry() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/systems/finbox"
    }

    Before 'setup_finalize_dry'
    After 'cleanup_finalize_dry'

    It "shows verify steps in dry-run"
      When run script scripts/finalize_update.sh -s finbox -k system -d
      The status should be success
      The error should include "[dry] verify"
    End

    It "shows destroy old clone"
      When run script scripts/finalize_update.sh -s finbox -k system -d
      The error should include "zfs destroy"
      The error should include "systems/finbox"
    End

    It "shows rename -new to plain"
      When run script scripts/finalize_update.sh -s finbox -k system -d
      The error should include "zfs rename"
      The error should include "finbox-new"
    End

    It "shows .foundation update"
      When run script scripts/finalize_update.sh -s finbox -k system -d
      The error should include "foundation"
    End

    It "shows save delegation"
      When run script scripts/finalize_update.sh -s finbox -k system -d
      The error should include "save.sh"
    End

    It "shows finalize complete"
      When run script scripts/finalize_update.sh -s finbox -k system -d
      The error should include "Finalize complete"
    End
  End

  Describe "container dry-run"
    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *-new|*containers*) exit 0 ;;
            *)                  exit 1 ;;
          esac
          ;;
        get) printf "no\n" ;;
        *) exit 0 ;;
      esac
    End

    Mock sync
      exit 0
    End

    Mock jail
      exit 0
    End

    setup_finalize_container() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/containers/finjail"
      printf "stable-15_2026-07-01_def5678\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/containers/finjail/15-stable-generic.foundation"
    }

    cleanup_finalize_container() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/containers/finjail"
    }

    Before 'setup_finalize_container'
    After 'cleanup_finalize_container'

    It "stops old container before destroy"
      When run script scripts/finalize_update.sh -s finjail -k container -d
      The error should include "Stopping old container"
      The error should include "jail -r finjail"
    End

    It "starts container after finalize"
      When run script scripts/finalize_update.sh -s finjail -k container -d
      The error should include "jail -c finjail"
    End

    It "auto-detects container kind"
      When run script scripts/finalize_update.sh -s finjail -d
      The status should be success
      The error should include "finjail"
    End
  End

  Describe "system nextboot"
    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *-new|*systems*) exit 0 ;;
            *)               exit 1 ;;
          esac
          ;;
        get) printf "no\n" ;;
        *) exit 0 ;;
      esac
    End

    Mock sync
      exit 0
    End

    setup_finalize_nextboot() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/systems/bootbox"
      printf "stable-15_2026-07-01_def5678\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/bootbox/15-stable-generic.foundation"
    }

    cleanup_finalize_nextboot() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/systems/bootbox"
    }

    Before 'setup_finalize_nextboot'
    After 'cleanup_finalize_nextboot'

    It "sets nextboot with -n flag"
      When run script scripts/finalize_update.sh -s bootbox -k system -d -n
      The error should include "nextboot"
    End
  End
End
