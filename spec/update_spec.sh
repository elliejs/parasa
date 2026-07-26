# shellcheck shell=sh
# Tests for scripts/update.sh

Describe "update.sh"
  Describe "help and argument parsing"
    It "prints help with -h"
      When run script scripts/update.sh -h
      The status should be success
      The output should include "update"
      The output should include "Usage:"
    End

    It "rejects unknown flags"
      When run script scripts/update.sh -Z
      The status should be failure
      The error should include "Unknown option"
    End

    It "requires -s NAME"
      When run script scripts/update.sh -q
      The status should be failure
      The error should include "name required"
    End
  End

  Describe "pre-flight checks"
    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *-new)              exit 0 ;;  # -new exists = collision
            *foundation.zfs*)  exit 0 ;;
            *)                 exit 1 ;;
          esac
          ;;
        get) printf "no\n" ;;
        *) exit 0 ;;
      esac
    End

    setup_update_preflight() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/systems/updatebox"
      printf "stable-15_2026-01-01_abc1234\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/updatebox/15-stable-generic.foundation"
    }

    cleanup_update_preflight() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/systems/updatebox"
    }

    Before 'setup_update_preflight'
    After 'cleanup_update_preflight'

    It "dies if -new already exists"
      When run script scripts/update.sh -s updatebox -k system -d
      The status should be failure
      The error should include "-new already exists"
    End
  End

  Describe "dry-run orchestration"
    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *-new)             exit 1 ;;  # no collision
            *foundation.zfs*) exit 0 ;;
            *foundations*)     exit 0 ;;
            *)                exit 1 ;;
          esac
          ;;
        get) printf "no\n" ;;
        send) exit 0 ;;
        *) exit 0 ;;
      esac
    End

    Mock git
      case "$*" in
        *rev-parse*) printf "abc1234\n" ;;
        *) exit 0 ;;
      esac
    End

    Mock sync
      exit 0
    End

    Mock jail
      exit 0
    End

    setup_update_dry() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/systems/dryupdate"
      printf "stable-15_2026-01-01_abc1234\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/dryupdate/15-stable-generic.foundation"
      printf "" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/dryupdate/compose.sh"
      printf "" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/dryupdate/pkg.list"
      printf "" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/dryupdate/derivations.local"
    }

    cleanup_update_dry() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/systems/dryupdate"
    }

    Before 'setup_update_dry'
    After 'cleanup_update_dry'

    It "runs the full pipeline in dry-run mode"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The status should be success
      The error should include "[dry]"
    End

    It "shows diff check in dry-run"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "diff.sh"
    End

    It "shows old and new artifact"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "stable-15_2026-01-01_abc1234"
      The error should include "stable-15_2026-07-01_def5678"
    End

    It "shows zfs clone into -new"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "zfs clone"
      The error should include "dryupdate-new"
    End

    It "shows git rebase"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "rebase"
    End

    It "shows derivation regen step"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "Regenerating derivations"
    End

    It "shows validation step"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "Validating"
    End

    It "shows success message"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "built successfully"
      The error should include "dryupdate-new"
    End

    It "shows finalize_update instruction"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "finalize_update"
    End

    It "dies when already at same artifact"
      When run script scripts/update.sh -s dryupdate -k system -a "stable-15_2026-01-01_abc1234" -d -q
      The status should be failure
      The error should include "Nothing to update"
    End
  End

  Describe "container dry-run"
    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *-new)             exit 1 ;;
            *foundation.zfs*) exit 0 ;;
            *foundations*)     exit 0 ;;
            *)                exit 1 ;;
          esac
          ;;
        get) printf "no\n" ;;
        *) exit 0 ;;
      esac
    End

    Mock git
      exit 0
    End

    Mock sync
      exit 0
    End

    Mock jail
      exit 0
    End

    setup_container_update() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/containers/updatejail"
      printf "stable-15_2026-01-01_abc1234\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/containers/updatejail/15-stable-generic.foundation"
      printf "" > "$SHELLSPEC_PROJECT_ROOT/recipes/containers/updatejail/compose.sh"
      printf "" > "$SHELLSPEC_PROJECT_ROOT/recipes/containers/updatejail/pkg.list"
      printf "" > "$SHELLSPEC_PROJECT_ROOT/recipes/containers/updatejail/derivations.local"
    }

    cleanup_container_update() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/containers/updatejail"
    }

    Before 'setup_container_update'
    After 'cleanup_container_update'

    It "uses jail commands for container"
      When run script scripts/update.sh -s updatejail -k container -a "stable-15_2026-07-01_def5678" -d -q
      The status should be success
      The error should include "jail"
    End

    It "uses jexec for container recipe"
      When run script scripts/update.sh -s updatejail -k container -a "stable-15_2026-07-01_def5678" -d -q
      The error should include "jexec"
    End

    It "auto-detects container kind"
      When run script scripts/update.sh -s updatejail -a "stable-15_2026-07-01_def5678" -d -q
      The status should be success
      The error should include "container"
    End
  End
End
