# shellcheck shell=sh
# Tests for scripts/save.sh

Describe "save.sh"
  Describe "help and argument parsing"
    It "prints help with -h"
      When run script scripts/save.sh -h
      The status should be success
      The output should include "save"
      The output should include "Usage:"
    End

    It "rejects unknown flags"
      When run script scripts/save.sh -Z
      The status should be failure
      The error should include "Unknown option"
    End

    It "requires -s NAME"
      When run script scripts/save.sh -q -m "test"
      The status should be failure
      The error should include "name required"
    End

    It "requires -m in quiet mode"
      When run script scripts/save.sh -s testbox -k system -q
      The status should be failure
      The error should include "message required"
    End
  End

  Describe "dry-run mode"
    setup_save_dry() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/systems/savebox"
      printf "stable-15_2026-01-01_abc1234\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/savebox/15-stable-generic.foundation"
    }

    cleanup_save_dry() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/systems/savebox"
    }

    Before 'setup_save_dry'
    After 'cleanup_save_dry'

    It "shows dry-run diff step"
      When run script scripts/save.sh -s savebox -k system -d -q -m "test"
      The status should be success
      The error should include "[dry] diff.sh"
    End

    It "shows dry-run pkg capture"
      When run script scripts/save.sh -s savebox -k system -d -q -m "test"
      The error should include "[dry] chroot"
      The error should include "pkg query"
    End

    It "shows dry-run mtree regen"
      When run script scripts/save.sh -s savebox -k system -d -q -m "test"
      The error should include "[dry] generate_mtree"
    End

    It "shows dry-run git commit and push"
      When run script scripts/save.sh -s savebox -k system -d -q -m "test"
      The error should include "[dry] git"
      The error should include "commit"
      The error should include "push"
    End

    It "shows dry-run recipe commit"
      When run script scripts/save.sh -s savebox -k system -d -q -m "test"
      The error should include "recipes/systems/savebox"
    End
  End

  Describe "container dry-run"
    setup_save_container() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/containers/savejail"
      printf "stable-15_2026-01-01_abc1234\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/containers/savejail/15-stable-generic.foundation"
    }

    cleanup_save_container() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/containers/savejail"
    }

    Before 'setup_save_container'
    After 'cleanup_save_container'

    It "uses pkg -j for containers"
      When run script scripts/save.sh -s savejail -k container -d -q -m "test"
      The error should include "[dry] pkg -j savejail"
    End

    It "auto-detects container kind"
      When run script scripts/save.sh -s savejail -d -q -m "test"
      The status should be success
      The error should include "savejail"
    End
  End
End
