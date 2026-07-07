#!/bin/sh

# 1. Help message and validation
if [ -z "$1" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
	echo "Usage: run_composition <file.ini> [KEY=VAL ...]"
	echo "Parses an INI file and executes its sections in a clean subshell."
	return 0
fi

if [ ! -f "$1" ]; then
	echo "Error: File '$1' not found."
	return 1
fi

# 2. Start Subshell (localized scope)
(
	config_file="$1"
	shift 1
	
	current_section=""
	PACKAGES=""

	# Parse the file
	while IFS= read -r line || [ -n "$line" ]; do
		# Strip comments and trim whitespace
		line=$(echo "$line" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -z "$line" ] && continue

		case "$line" in
			\[*\])
				current_section=$(echo "$line" | tr -d '[]')
				continue
				;;
		esac

		case "$current_section" in
			env)
				key=$(echo "$line" | cut -d'=' -f1)
				val=$(echo "$line" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
				export "$key"="$val"
				JAIL_ENV_OVERRIDE="$JAIL_ENV_OVERRIDE $key='$val'"
				;;
			pkg)
				PACKAGES="$PACKAGES $line"
				;;
			cmd)
				# We defer commands until env/pkgs are fully processed
				COMMANDS="${COMMANDS}${line}
"
				;;
			pre)
				PRE_COMMANDS="${PRE_COMMANDS}${line}
"
				;;
		esac
	done < "$config_file"

	# 3. Apply manual overrides from arguments ($@)
	for override in "$@"; do
		export "$override"
		# Extract the key and value to ensure safe quoting for the jail
		key=$(echo "$override" | cut -d'=' -f1)
		val=$(echo "$override" | cut -d'=' -f2-)
		# Append it to our jail "suitcase" variable
		JAIL_ENV_OVERRIDE="$JAIL_ENV_OVERRIDE $key='$val'"
	done

	[ -n "$name" ] || {
		echo "Need to set name=[JAIL_NAME] in the cfg"
		exit 1
	}
	# 4. Execution Phase
	echo "--- Executing: $config_file ---"

		# Execute commands line by line
	echo "PRE-pkg command execution"
	echo "Environment: $JAIL_ENV_OVERRIDE"
	echo "Commands: $COMMANDS"
	printf "%s" "$PRE_COMMANDS" | while IFS= read -r cmd; do
		[ -z "$cmd" ] && continue
		echo "Running: $cmd"
		jexec "$name" env $JAIL_ENV_OVERRIDE sh -c "$cmd"
	done

	# Example: Handle packages (e.g., apk, apt, pkg)
	if [ -n "$PACKAGES" ]; then
		echo "Installing packages: $PACKAGES"
		# pkg_cmd install $PACKAGES
		yes | pkg -j "${name}" install ${PACKAGES}
	fi

	# Execute commands line by line
	echo "POST-pkg command execution"
	echo "Environment: $JAIL_ENV_OVERRIDE"
	echo "Commands: $COMMANDS"
	printf "%s" "$COMMANDS" | while IFS= read -r cmd; do
		[ -z "$cmd" ] && continue
		echo "Running: $cmd"
		jexec "$name" env $JAIL_ENV_OVERRIDE sh -c "$cmd"
	done
)

# --- Examples of use ---

# 1. Normal run
# run_ini setup.ini

# 2. Run with overrides (root_dir will be changed even if set in ini)
# run_ini setup.ini root_dir="/tmp/test" debug=true

# 3. Show help
# run_ini -h
