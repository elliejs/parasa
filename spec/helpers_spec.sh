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

    It "reads from build.cfg when present"
      printf 'SRC_BRANCH=stable/14\n' > "$SHELLSPEC_TMPDIR/conf_msysrc/build.cfg"
      When call msysrc "$SHELLSPEC_TMPDIR/conf_msysrc/build.cfg" SRC_BRANCH
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

  # ── New Phase 1 helpers ────────────────────────────────────────────────────

  Describe "get_tree_root()"
    It "returns system path"
      When call get_tree_root "system" "wonderland"
      The output should equal "/zbereshit/systems/wonderland"
    End

    It "returns container path"
      When call get_tree_root "container" "webserver"
      The output should equal "/containers/webserver"
    End

    It "dies on unknown kind"
      When run get_tree_root "bogus" "x"
      The status should be failure
      The error should include "unknown kind"
    End
  End

  Describe "get_recipes_dir()"
    setup_recipes_dir_env() {
      PARASA_DIR="/fakedir"
      export PARASA_DIR
    }
    Before 'setup_recipes_dir_env'

    It "returns system recipes path"
      When call get_recipes_dir "system" "wonderland"
      The output should equal "/fakedir/recipes/systems/wonderland"
    End

    It "returns container recipes path"
      When call get_recipes_dir "container" "webserver"
      The output should equal "/fakedir/recipes/containers/webserver"
    End
  End

  Describe "detect_kind()"
    setup_detect_kind() {
      PARASA_DIR="$SHELLSPEC_TMPDIR/detect_kind_root"
      export PARASA_DIR
      mkdir -p "$PARASA_DIR/recipes/systems/boxA"
      mkdir -p "$PARASA_DIR/recipes/containers/boxB"
      mkdir -p "$PARASA_DIR/recipes/systems/both"
      mkdir -p "$PARASA_DIR/recipes/containers/both"
    }
    Before 'setup_detect_kind'

    It "detects a system"
      When call detect_kind "boxA"
      The output should equal "system"
    End

    It "detects a container"
      When call detect_kind "boxB"
      The output should equal "container"
    End

    It "dies if both system and container exist"
      When run detect_kind "both"
      The status should be failure
      The error should include "both system and container"
    End

    It "dies if not found"
      When run detect_kind "nonexistent"
      The status should be failure
      The error should include "not found"
    End
  End

  Describe "is_binary_file()"
    Mock file
      case "$2" in
        *elf_bin)  printf "ELF 64-bit LSB executable\n" ;;
        *data_bin) printf "data\n" ;;
        *text_file) printf "ASCII text\n" ;;
        *) printf "empty\n" ;;
      esac
    End

    setup_binary_files() {
      _bdir="$SHELLSPEC_TMPDIR/binfiles"
      mkdir -p "$_bdir"
      touch "$_bdir/elf_bin" "$_bdir/data_bin" "$_bdir/text_file"
    }
    Before 'setup_binary_files'

    It "returns success (0) for ELF binaries"
      When call is_binary_file "$_bdir/elf_bin"
      The status should be success
    End

    It "returns success (0) for data files"
      When call is_binary_file "$_bdir/data_bin"
      The status should be success
    End

    It "returns failure (1) for text files"
      When call is_binary_file "$_bdir/text_file"
      The status should be failure
    End

    It "returns failure for nonexistent files"
      When call is_binary_file "$_bdir/nosuchfile"
      The status should be failure
    End
  End

  Describe "lookup_derivation()"
    setup_derivation_dbs() {
      _dbdir="$SHELLSPEC_TMPDIR/derivdbs"
      mkdir -p "$_dbdir"
      printf "etc/master.passwd\tetc/pwd.db\tpwd_mkdb -p -d /etc /etc/master.passwd\n" > "$_dbdir/global.db"
      printf "etc/login.conf\tetc/login.conf.db\tcap_mkdb /etc/login.conf\n" >> "$_dbdir/global.db"
      printf "usr/local/etc/app.conf\tusr/local/etc/app.db\tapp_mkdb /usr/local/etc/app.conf\n" > "$_dbdir/local.db"
    }
    Before 'setup_derivation_dbs'

    It "finds entries in the global db"
      When call lookup_derivation "etc/pwd.db" "$_dbdir/global.db"
      The status should be success
      The output should include "etc/master.passwd"
      The output should include "pwd_mkdb"
    End

    It "finds entries in the local db"
      When call lookup_derivation "usr/local/etc/app.db" "$_dbdir/global.db" "$_dbdir/local.db"
      The status should be success
      The output should include "app.conf"
      The output should include "app_mkdb"
    End

    It "returns failure for unknown paths"
      When call lookup_derivation "etc/unknown" "$_dbdir/global.db" "$_dbdir/local.db"
      The status should be failure
    End

    It "handles missing db files gracefully"
      When call lookup_derivation "etc/pwd.db" "$_dbdir/nonexistent.db"
      The status should be failure
    End
  End

  # ── Version resolution helpers ───────────────────────────────────────────

  Describe "branch_to_version()"
    It "converts stable/15 to 15.0"
      When call branch_to_version "stable/15"
      The output should equal "15.0"
    End

    It "converts releng/15.1 to 15.1"
      When call branch_to_version "releng/15.1"
      The output should equal "15.1"
    End

    It "converts releng/14.2 to 14.2"
      When call branch_to_version "releng/14.2"
      The output should equal "14.2"
    End

    It "passes through main unchanged"
      When call branch_to_version "main"
      The output should equal "main"
    End
  End

  Describe "ver_ge()"
    It "15.1 >= 15.0 is true"
      When call ver_ge "15.1" "15.0"
      The status should be success
    End

    It "15.0 >= 15.0 is true"
      When call ver_ge "15.0" "15.0"
      The status should be success
    End

    It "14.0 >= 15.0 is false"
      When call ver_ge "14.0" "15.0"
      The status should be failure
    End

    It "16.0 >= 15.1 is true"
      When call ver_ge "16.0" "15.1"
      The status should be success
    End

    It "15.0 >= 15.1 is false"
      When call ver_ge "15.0" "15.1"
      The status should be failure
    End
  End

  Describe "resolve_derivations_db()"
    setup_deriv_dbs() {
      PARASA_DIR="$SHELLSPEC_TMPDIR/deriv_resolve"
      export PARASA_DIR
      mkdir -p "$PARASA_DIR/etc/derivations"
      printf "# 14.0 derivations\n" > "$PARASA_DIR/etc/derivations/14.0.db"
      printf "# 15.0 derivations\n" > "$PARASA_DIR/etc/derivations/15.0.db"
    }
    Before 'setup_deriv_dbs'

    It "finds exact version match"
      When call resolve_derivations_db "15.0"
      The status should be success
      The output should include "15.0.db"
    End

    It "finds newest <= for higher version"
      When call resolve_derivations_db "15.1"
      The status should be success
      The output should include "15.0.db"
    End

    It "finds 14.0 for version 14.2"
      When call resolve_derivations_db "14.2"
      The status should be success
      The output should include "14.0.db"
    End

    It "uses newest db for main"
      When call resolve_derivations_db "main"
      The status should be success
      The output should include "15.0.db"
    End

    It "fails for version older than all dbs"
      When call resolve_derivations_db "13.0"
      The status should be failure
    End
  End

  Describe "read_artifact_name()"
    setup_artifact_dir() {
      _adir="$SHELLSPEC_TMPDIR/artifact_read"
      mkdir -p "$_adir"
      printf "stable-15_2026-01-01_abc1234\n" > "$_adir/15-stable-generic.foundation"
    }
    Before 'setup_artifact_dir'

    It "reads the artifact name from .foundation file"
      When call read_artifact_name "$_adir"
      The output should equal "stable-15_2026-01-01_abc1234"
    End

    It "dies if .foundation file is missing"
      _empty="$SHELLSPEC_TMPDIR/artifact_empty"
      mkdir -p "$_empty"
      When run read_artifact_name "$_empty"
      The status should be failure
      The error should include "no .foundation file"
    End

    It "dies if .foundation file is empty"
      _zerodir="$SHELLSPEC_TMPDIR/artifact_zero"
      mkdir -p "$_zerodir"
      : > "$_zerodir/test.foundation"
      When run read_artifact_name "$_zerodir"
      The status should be failure
      The error should include "empty"
    End
  End
End
