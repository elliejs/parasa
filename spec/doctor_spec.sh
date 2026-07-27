# shellcheck shell=sh
# Tests for scripts/doctor.sh

Describe "doctor.sh"
  Describe "help and argument parsing"
    It "prints help with -h"
      When run script scripts/doctor.sh -h
      The status should be success
      The output should include "doctor"
      The output should include "Usage:"
    End

    It "rejects unknown flags"
      When run script scripts/doctor.sh -Z
      The status should be failure
      The error should include "Unknown option"
    End
  End

  Describe "tool checks"
    Include scripts/helpers.sh

    # We can test the check logic by running in quiet mode.
    # The script will find tools on this system or not.

    It "reports on required tools in quiet mode"
      # On any system, at least git and file should exist
      When run script scripts/doctor.sh -q
      # It will fail because we don't have ZFS pools, but it runs
      The status should be failure
      The error should include "Doctor summary"
    End
  End

  Describe "parasa repo integrity"
    # The script runs from within the repo, so repo checks should pass.
    # Not using -q so pass messages are visible.

    Mock zpool
      exit 1
    End

    Mock zfs
      case "$1" in
        list) exit 1 ;;
        get)  exit 1 ;;
        *)    exit 0 ;;
      esac
    End

    Mock uname
      case "$1" in
        -s) printf "FreeBSD" ;;
        -r) printf "15.0-RELEASE" ;;
        *)  printf "FreeBSD" ;;
      esac
    End

    It "detects parasa repo as valid git repository"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "parasa repo is a git repository"
    End

    It "detects etc/mtree.ignore"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "etc/mtree.ignore"
    End

    It "detects derivation db files"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "derivations"
      The error should include "db file"
    End

    It "detects recipes/ directories"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "recipes/"
    End

    It "detects recipes/jail.conf"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "recipes/jail.conf"
    End

    It "detects scripts"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "scripts/helpers.sh"
      The error should include "scripts/diff.sh"
    End

    It "shows summary"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "Doctor summary"
      The error should include "Passed:"
      The error should include "Failed:"
    End
  End

  Describe "pool detection (mocked)"
    Mock zpool
      case "$*" in
        *zbereshit*) exit 0 ;;
        *zshemot*)   exit 0 ;;
        *zbamidbar*) exit 0 ;;
        *)           exit 1 ;;
      esac
    End

    Mock zfs
      case "$1" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            zbereshit*|zshemot*|zbamidbar*) exit 0 ;;
            *) exit 1 ;;
          esac
          ;;
        get)
          printf "none\n"
          ;;
        *) exit 0 ;;
      esac
    End

    Mock uname
      case "$1" in
        -s) printf "FreeBSD" ;;
        -r) printf "15.0-RELEASE" ;;
        *)  printf "FreeBSD" ;;
      esac
    End

    Mock sync
      exit 0
    End

    It "passes when all pools and datasets exist"
      When run script scripts/doctor.sh
      The error should include "pool zbereshit exists"
      The error should include "pool zshemot exists"
      The error should include "pool zbamidbar exists"
    End

    It "passes FreeBSD check"
      When run script scripts/doctor.sh
      The error should include "Running FreeBSD"
    End

    It "passes dataset checks"
      When run script scripts/doctor.sh
      The error should include "zbereshit/foundations"
      The error should include "zbereshit/systems"
      The error should include "zbereshit/containers"
      The error should include "zshemot/buildspace"
    End

    It "exits success when everything checks out"
      When run script scripts/doctor.sh
      The status should be success
      The error should include "System layout is ready"
    End
  End

  Describe "missing pool detection"
    Mock zpool
      exit 1
    End

    Mock zfs
      case "$1" in
        list) exit 1 ;;
        get)  exit 1 ;;
        *)    exit 0 ;;
      esac
    End

    Mock uname
      case "$1" in
        -s) printf "FreeBSD" ;;
        -r) printf "15.0-RELEASE" ;;
        *)  printf "FreeBSD" ;;
      esac
    End

    It "reports missing pools"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "pool zbereshit not found"
      The error should include "pool zshemot not found"
      The error should include "pool zbamidbar not found"
    End

    It "reports problems remain"
      When run script scripts/doctor.sh
      The status should be failure
      The error should include "problem(s) remain"
    End
  End
End
