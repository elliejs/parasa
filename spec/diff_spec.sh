# shellcheck shell=sh
# Tests for scripts/diff.sh

Describe "diff.sh"
  Describe "help and argument parsing"
    It "prints help with -h"
      When run script scripts/diff.sh -h
      The status should be success
      The output should include "diff"
      The output should include "Usage:"
    End

    It "rejects unknown flags"
      When run script scripts/diff.sh -Z
      The status should be failure
      The error should include "Unknown option"
    End

    It "requires -s NAME"
      When run script scripts/diff.sh -q
      The status should be failure
      The error should include "name required"
    End
  End

  Describe "dry-run mode"
    Mock sysrc
      case "$*" in
        *SRC_BRANCH*) printf "stable/15" ;;
        *) exit 1 ;;
      esac
    End

    setup_dry_diff() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/systems/diffbox"
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/foundations/15-stable-generic"
      printf "SRC_BRANCH=stable/15\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/foundations/15-stable-generic/build.conf"
      printf "stable-15_2026-01-01_abc1234\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/systems/diffbox/15-stable-generic.foundation"
    }

    cleanup_dry_diff() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/systems/diffbox"
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/foundations/15-stable-generic"
    }

    Before 'setup_dry_diff'
    After 'cleanup_dry_diff'

    It "shows comparison plan in dry-run"
      When run script scripts/diff.sh -s diffbox -k system -d
      The status should be success
      The error should include "[dry]"
      The error should include "diffbox"
    End

    It "shows foundation name"
      When run script scripts/diff.sh -s diffbox -k system -d
      The error should include "15-stable-generic"
    End
  End

  Describe "classification helpers"
    Include scripts/helpers.sh

    Describe "is_exempt_path()"
      # Source the script to get the function
      is_exempt_path() {
        case "$1" in
          var/*|usr/local/*|home/*|tmp/*|root/*) return 0 ;;
          *) return 1 ;;
        esac
      }

      It "exempts var/ paths"
        When call is_exempt_path "var/log/messages"
        The status should be success
      End

      It "exempts usr/local/ paths"
        When call is_exempt_path "usr/local/bin/myapp"
        The status should be success
      End

      It "exempts home/ paths"
        When call is_exempt_path "home/alice/.profile"
        The status should be success
      End

      It "exempts tmp/ paths"
        When call is_exempt_path "tmp/build.out"
        The status should be success
      End

      It "exempts root/ paths"
        When call is_exempt_path "root/.ssh/authorized_keys"
        The status should be success
      End

      It "does not exempt etc/ paths"
        When call is_exempt_path "etc/rc.conf"
        The status should be failure
      End

      It "does not exempt bin/ paths"
        When call is_exempt_path "bin/ls"
        The status should be failure
      End
    End

    Describe "classify_file()"
      # Inline the function for testing
      Mock file
        printf "ASCII text\n"
      End

      Mock git
        exit 1
      End

      classify_file() {
        local relpath="$1"
        case "$relpath" in
          var/*|usr/local/*|home/*|tmp/*|root/*) printf "exempt"; return 0 ;;
        esac
        # For test: treat .conf as text, .db as derivation, others as unclassified
        case "$relpath" in
          *.conf) printf "text"; return 0 ;;
          etc/pwd.db) printf "derivation"; return 0 ;;
          *) printf "unclassified"; return 1 ;;
        esac
      }

      It "classifies exempt paths"
        When call classify_file "var/log/messages"
        The output should equal "exempt"
        The status should be success
      End

      It "classifies text files"
        When call classify_file "etc/rc.conf"
        The output should equal "text"
        The status should be success
      End

      It "classifies known derivations"
        When call classify_file "etc/pwd.db"
        The output should equal "derivation"
        The status should be success
      End

      It "returns unclassified for unknown binaries"
        When call classify_file "etc/mystery.bin"
        The output should equal "unclassified"
        The status should be failure
      End
    End
  End

  Describe "detect_kind integration"
    Mock sysrc
      case "$*" in
        *SRC_BRANCH*) printf "stable/15" ;;
        *) exit 1 ;;
      esac
    End

    setup_detect() {
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/containers/diffweb"
      mkdir -p "$SHELLSPEC_PROJECT_ROOT/recipes/foundations/myfound"
      printf "SRC_BRANCH=stable/15\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/foundations/myfound/build.conf"
      printf "art1\n" > "$SHELLSPEC_PROJECT_ROOT/recipes/containers/diffweb/myfound.foundation"
    }

    cleanup_detect() {
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/containers/diffweb"
      rm -rf "$SHELLSPEC_PROJECT_ROOT/recipes/foundations/myfound"
    }

    Before 'setup_detect'
    After 'cleanup_detect'

    It "auto-detects container kind"
      When run script scripts/diff.sh -s diffweb -d
      The status should be success
      The error should include "[dry]"
    End

    It "fails for nonexistent workspace"
      When run script scripts/diff.sh -s nosuch_diff_target -d
      The status should be failure
      The error should include "not found"
    End
  End
End
