# shellcheck shell=sh
# Tests for scripts/new_container.sh -- argument parsing and help.

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
  End
End
