# shellcheck shell=sh
# Tests for scripts/helpers.sh

Describe "helpers.sh"
  Include scripts/helpers.sh

  Describe "error()"
    It "prints to stderr and returns 1"
      When call error "test failure"
      The status should be failure
      The error should include "ERROR: test failure"
    End
  End

  Describe "yesish()"
    Parameters
      "yes"   success
      "YES"   success
      "y"     success
      "Y"     success
      "true"  success
      "True"  success
      "TRUE"  success
      "1"     success
      "t"     success
      "T"     success
      ""      success
      "no"    failure
      "false" failure
      "0"     failure
      "maybe" failure
    End

    It "returns $2 for '$1'"
      When call yesish "$1"
      The status should be "$2"
    End
  End

  Describe "noish()"
    Parameters
      "no"    success
      "NO"    success
      "n"     success
      "N"     success
      "false" success
      "FALSE" success
      "0"     success
      "f"     success
      "F"     success
      "yes"   failure
      ""      failure
      "maybe" failure
    End

    It "returns $2 for '$1'"
      When call noish "$1"
      The status should be "$2"
    End
  End

  Describe "validate_name()"
    It "accepts simple alphanumeric names"
      When call validate_name "myhost01"
      The status should be success
    End

    It "accepts hyphens, underscores, and dots"
      When call validate_name "my_host-01.stable"
      The status should be success
    End

    It "rejects empty names"
      When call validate_name ""
      The status should be failure
      The error should include "cannot be empty"
    End

    It "rejects names starting with a hyphen"
      When call validate_name "-badname"
      The status should be failure
      The error should include "cannot start with a hyphen"
    End

    It "rejects names with spaces"
      When call validate_name "bad name"
      The status should be failure
      The error should include "may only contain"
    End

    It "rejects names with slashes"
      When call validate_name "bad/name"
      The status should be failure
      The error should include "may only contain"
    End

    It "uses custom label in error messages"
      When call validate_name "" "Foundation"
      The status should be failure
      The error should include "Foundation cannot be empty"
    End
  End

  Describe "get_foundation()"
    Describe "with a single .foundation file"
      setup_single() {
        _mdir="$SHELLSPEC_TMPDIR/recipe_single"
        mkdir -p "$_mdir"
        touch "$_mdir/generic-stable15.foundation"
      }
      Before 'setup_single'

      It "reads the foundation name"
        When call get_foundation "$_mdir"
        The output should equal "generic-stable15"
      End
    End

    Describe "with no .foundation file"
      setup_none() {
        _mdir="$SHELLSPEC_TMPDIR/recipe_none"
        mkdir -p "$_mdir"
      }
      Before 'setup_none'

      It "dies"
        When run get_foundation "$_mdir"
        The status should be failure
        The error should include "no .foundation file"
      End
    End

    Describe "with multiple .foundation files"
      setup_multi() {
        _mdir="$SHELLSPEC_TMPDIR/recipe_multi"
        mkdir -p "$_mdir"
        touch "$_mdir/one.foundation"
        touch "$_mdir/two.foundation"
      }
      Before 'setup_multi'

      It "dies"
        When run get_foundation "$_mdir"
        The status should be failure
        The error should include "expected 1"
      End
    End
  End

  Describe "prompt_or_default()"
    It "returns the default in quiet mode"
      When call prompt_or_default "Enter value" "mydefault" 1
      The output should equal "mydefault"
    End

    It "returns user input when not quiet"
      Data "custom_value"
      When call prompt_or_default "Enter value" "mydefault" 0
      The output should equal "custom_value"
      The error should include "Enter value"
    End

    It "returns default on empty input when not quiet"
      Data ""
      When call prompt_or_default "Enter value" "mydefault" 0
      The output should equal "mydefault"
      The error should include "Enter value"
    End
  End

  Describe "prompt_yesno()"
    It "returns yes (0) in quiet mode with yes default"
      When call prompt_yesno "Continue?" "yes" 1
      The status should be success
    End

    It "returns no (1) in quiet mode with no default"
      When call prompt_yesno "Continue?" "no" 1
      The status should be failure
    End

    It "returns yes on 'y' input"
      Data "y"
      When call prompt_yesno "Continue?" "no" 0
      The status should be success
      The error should include "Continue?"
    End

    It "returns no on 'n' input"
      Data "n"
      When call prompt_yesno "Continue?" "yes" 0
      The status should be failure
      The error should include "Continue?"
    End

    It "uses default on empty input"
      Data ""
      When call prompt_yesno "Continue?" "yes" 0
      The status should be success
      The error should include "Continue?"
    End
  End

  Describe "msysrc()"
    Mock sysrc
      _file="" _var="" _skip=""
      for _a in "$@"; do
        case "$_skip" in
          f) _file="$_a"; _skip=""; continue ;;
        esac
        case "$_a" in
          -f) _skip="f" ;;
          -qn) _skip="v" ;;
          *)
            if [ "$_skip" = "v" ]; then
              _var="$_a"; _skip=""
            fi
            ;;
        esac
      done
      if [ -f "$_file" ]; then
        _val=$(grep "^${_var}=" "$_file" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"//;s/"$//')
        if [ -n "$_val" ]; then
          printf "%s" "$_val"
          exit 0
        fi
      fi
      exit 1
    End

    setup_msysrc_env() {
      PARASA_DIR="$SHELLSPEC_TMPDIR/parasa_msysrc"
      export PARASA_DIR
      mkdir -p "$PARASA_DIR"
      mkdir -p "$SHELLSPEC_TMPDIR/conf_msysrc"
    }
    Before 'setup_msysrc_env'

    It "reads from build.conf when present"
      printf 'SRC_BRANCH=stable/14\n' > "$SHELLSPEC_TMPDIR/conf_msysrc/build.conf"
      When call msysrc "$SHELLSPEC_TMPDIR/conf_msysrc/build.conf" SRC_BRANCH
      The output should equal "stable/14"
    End

    It "falls back to parasa.conf when value is set there"
      printf 'SRC_BRANCH=stable/15\n' > "$PARASA_DIR/parasa.conf"
      When call msysrc "$SHELLSPEC_TMPDIR/conf_msysrc/nonexistent.conf" SRC_BRANCH
      The output should equal "stable/15"
    End

    It "returns the default when nothing is found"
      When call msysrc "$SHELLSPEC_TMPDIR/conf_msysrc/nonexistent.conf" NONEXISTENT_VAR "fallback_val"
      The output should equal "fallback_val"
    End

    It "fails with no default and no match"
      When call msysrc "$SHELLSPEC_TMPDIR/conf_msysrc/nonexistent.conf" NONEXISTENT_VAR
      The status should be failure
    End
  End

  Describe "zfs helpers with mocked zfs"
    Mock zfs
      _cmd="$1"; shift
      case "$_cmd" in
        list)
          _last=""
          for _a in "$@"; do _last="$_a"; done
          case "$_last" in
            *exists*) printf "%s\n" "$_last"; exit 0 ;;
            *)        exit 1 ;;
          esac
          ;;
        set|mount|unmount|create|snapshot|send|recv)
          exit 0
          ;;
      esac
      exit 0
    End

    Mock sync
      exit 0
    End

    Describe "zfs_dataset_exists()"
      It "returns success for existing datasets"
        When call zfs_dataset_exists "pool/exists"
        The status should be success
      End

      It "returns failure for missing datasets"
        When call zfs_dataset_exists "pool/missing"
        The status should be failure
      End
    End

    Describe "ztouch()"
      It "succeeds for new datasets"
        When call ztouch "pool/new_dataset"
        The status should be success
      End

      It "succeeds for existing datasets (no-op)"
        When call ztouch "pool/exists"
        The status should be success
      End
    End

    Describe "zmount()"
      It "mounts a dataset at a given path"
        When call zmount "pool/data" "/mnt/data"
        The status should be success
      End
    End

    Describe "zunmount()"
      It "unmounts a dataset"
        When call zunmount "pool/data"
        The status should be success
      End
    End
  End

  Describe "get_artifact_name()"
    setup_artifact_repo() {
      _repo="$SHELLSPEC_TMPDIR/artifactrepo"
      if [ ! -d "$_repo/.git" ]; then
        mkdir -p "$_repo"
        git -C "$_repo" init -q
        git -C "$_repo" config user.email "test@test.com"
        git -C "$_repo" config user.name "test"
        printf "x" > "$_repo/file"
        git -C "$_repo" add file
        git -C "$_repo" commit -q -m "initial"
      fi
    }
    Before 'setup_artifact_repo'

    It "produces a name with branch, date, and short sha"
      When call get_artifact_name "$_repo" "mysuffix"
      The output should match pattern "*_*_*_mysuffix"
    End

    It "works without a suffix"
      When call get_artifact_name "$_repo"
      The output should match pattern "*_*_*"
    End

    It "dies on non-git directory"
      When run get_artifact_name "/tmp" ""
      The status should be failure
      The error should include "not a git repo"
    End
  End
End
