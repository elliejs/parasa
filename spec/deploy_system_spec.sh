# shellcheck shell=sh
# Tests for scripts/deploy_system.sh -- argument parsing and help.

Describe "deploy_system.sh"
  Describe "help and argument parsing"
    It "prints help with -h"
      When run script scripts/deploy_system.sh -h
      The status should be success
      The output should include "deploy_system"
      The output should include "Usage:"
    End

    It "rejects unknown flags"
      When run script scripts/deploy_system.sh -Z
      The status should be failure
      The error should include "Unknown option"
    End

    It "requires -s NAME"
      Mock id
        printf "0\n"
      End
      When run script scripts/deploy_system.sh
      The status should be failure
      The error should include "System name required"
    End
  End
End
