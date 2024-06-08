# =============================================================================
# fish-kubecompletions | Copyright (C) 2024 eth-p
#
# A kubectx/kubens replacement that sets the kubectl config file, context, and
# namespace for each individual instance of the fish shell.
#
# Documentation: https://github.com/eth-p/fish-kubecompletions/tree/master/docs
# Repository:    https://github.com/eth-p/fish-kubecompletions
# Issues:        https://github.com/eth-p/fish-kubecompletions/issues
# =============================================================================

if not command -vq kubectl
    return
end

# -----------------------------------------------------------------------------
# Global variables:
# -----------------------------------------------------------------------------

set -g __kubecompletions_plugins
set -g __kubecompletions_comps_provider
set -g __kubecompletions_comps_extras
set -g __kubecompletions_comps

# -----------------------------------------------------------------------------
# Helper functions:
# -----------------------------------------------------------------------------

if type -q __kubectl_debug
	function __kubecompletions_debug
		__kubectl_debug (string replace -- "{P}" "kubecompletions" "$argv")
	end
else
	function __kubecompletions_debug
	end
end

function __kubecompletions_add_plugin
    argparse 'd/description=' 'e/executable=' 'K/kubecli-completion-provider=' -- $argv \
        || return $status

    if not command -vq -- "$_flag_executable"
        return 1
    end

    # Compress the plugin information into a single eval-able block.
    set -l pdesc (
        printf "set -l plugin_command %s; set -l plugin_command_string %s; set -l plugin_description %s; set -l plugin_executable %s; set -l plugin_kubecli_completion_provider %s" \
        (string join -- " " (string escape -- $argv)) \
        (string escape -- (string join -- " " (string escape -- $argv))) \
        (string escape -- "$_flag_description") \
        (string escape -- "$_flag_executable") \
        (string escape -- "$_flag_kubecli_completion_provider")
    )

    eval "$pdesc"
    set -ga __kubecompletions_plugins "$pdesc"

    __kubecompletions_debug "$plugin_command ($plugin_description)"

    # Load the on-demand completion provider for the given plugin.
    #
    # The completion provider doesn't understand that it's called through `kubectl`,
    # so we need to trim the response returned by `commandline` to make it think that
    # it's being called directly.
    if test -n "$plugin_kubecli_completion_provider"
        set -l provider_commandline_fn "__$plugin_kubecli_completion_provider"__get_commandline
        set -l provider_commandline_strip (math (count $plugin_command) + 1)

        # Create the hooked `commandline` function.
        functions -e $provider_commandline_fn
        function $provider_commandline_fn \
            --inherit-variable plugin_executable \
            --inherit-variable provider_commandline_strip

            switch "$argv"
                # Current command excluding last argument.
                # Replace it with the executable name and sliced arguments.
                case "-opc"
                    __kubecompletions_debug "[{P}] providing modified commandline for $plugin_executable"
                    printf "%s\n" "$plugin_executable"
                    commandline -opc | sed 1,"$provider_commandline_strip"d
                    return $status

                # Last argument.
                # This could be the kubectl plugin name if there isn't a space after it.
                case "-ct"
                    if test (count (commandline -opc)) -lt $provider_commandline_strip
                        # If it's the plugin name, replace it with an empty string.
                        printf "\n"
                        return 0
                    end

                    commandline -ct
                    return $status

                # Any other case.
                case "*"
                    commandline $argv
                    return $status
            end
        end

        # Source the completion provider.
        "$plugin_executable" completion fish \
            | string replace -- "(commandline" "($provider_commandline_fn" \
            | source
    end
end

function __kubecompletions_str_startswith
    test (string sub --length (string length -- "$argv[2]") -- "$argv[1]") = "$argv[2]"
    return $status
end

# -----------------------------------------------------------------------------
# Completion provider:
# -----------------------------------------------------------------------------

function __kubecompletions_completions_clear
    set -g __kubecompletions_comps_extras
    set -g __kubecompletions_comps_provider

    # Clear kubectl completions.
    __kubectl_clear_perform_completion_once_result

    # Clear plugin completions.
    for plugin in $__kubecompletions_plugins
        eval "$plugin"
        eval "__""$plugin_kubecli_completion_provider""_clear_perform_completion_once_result"
    end
end

function __kubecompletions_select_provider
    set -l cli_args $argv[3..] (string unescape -- "$argv[1]")
    set -l cli_str "$cli_args"
    set -l end_arg_index (count $cli_args)

    __kubecompletions_debug
    __kubecompletions_debug "========== {P}: resolving completions provider =========="
    __kubecompletions_debug "end arg index: $end_arg_index"
    __kubecompletions_debug "cli:   $cli_str"


    # Iterate through plugins, selecing whichever one.
    for plugin in $__kubecompletions_plugins
        eval "$plugin"
        __kubecompletions_debug "maybe? $plugin_command_string"

        # If the current commandline is prefixed by the plugin command, switch providers.
        # For example: command `argo rollouts` prefixes cli `argo rollouts get`
        if __kubecompletions_str_startswith "$cli_str" "$plugin_command_string "
            __kubecompletions_debug "-> Using provider $plugin_kubecli_completion_provider."
            set -g __kubecompletions_comps_provider "$plugin_kubecli_completion_provider"
            return
        end

        # If the plugin command is prefixed by the current commandline, add it as an additional completion.
        # For example: cli `argo r` prefixes command `argo rollouts`
        if __kubecompletions_str_startswith "$plugin_command_string" "$cli_str"
            __kubecompletions_debug "-> Add completion $plugin_command[$end_arg_index]"
            set -ga __kubecompletions_comps_extras "$plugin_command[$end_arg_index]"\t"$plugin_description"
        end
    end

    # If we have our own completions for a kubectl subcommand, use a null provider.
    if test -n "$__kubecompletions_comps_extras" \
        && test "$end_arg_index" -gt 1
        set -g __kubecompletions_comps_provider "<null>"
        return
    end

    # Otherwise, use kubectl.
    set -g __kubecompletions_comps_provider kubectl
end

function __kubecompletions_completions_generate
    # Get command line.
    set -l args (commandline -opc)
    set -l lastArg (string escape -- (commandline -ct))

    # Resolve the completion provider.
    if test -z "$__kubecompletions_comps_provider"
        __kubecompletions_select_provider $lastArg $args
    end

    # If the completion provider is disabled, return just the extra completions.
    if test "$__kubecompletions_comps_provider" = "<null>"
        set -g __kubecompletions_comps $__kubecompletions_comps_extras
        set -g __kubecompletions_comps_extras # clear to prevent duplication
        return
    end

    # Run the completion provider and copy the completions.
    __kubecompletions_debug
    __kubecompletions_debug "========== {P}: completions generator ($argv[1]) =========="
    set -l comp_result 1
    switch "$argv[1]"
        case no-order
            eval "not __""$__kubecompletions_comps_provider""_requires_order_preservation && __""$__kubecompletions_comps_provider""_prepare_completions"
            set comp_result $status

        case keep-order
            eval "__""$__kubecompletions_comps_provider""_requires_order_preservation && __""$__kubecompletions_comps_provider""_prepare_completions"
            set comp_result $status

		case kubecompletions
			if test -n "$__kubecompletions_comps_extras"
				__kubecompletions_debug "!!!extras"
				set -g __kubecompletions_comps $__kubecompletions_comps_extras
				set -g __kubecompletions_comps_extras
				set comp_result 0
				return 0
			end
    end

    eval "set -g __kubecompletions_comps \$__""$__kubecompletions_comps_provider""_comp_results"
    return $comp_result
end

# -----------------------------------------------------------------------------
# Plugins:
# -----------------------------------------------------------------------------

__kubecompletions_debug "========= {P}: setting up plugin completions ========="

# Set up `kubectl argo rollouts` completions.
__kubecompletions_add_plugin argo rollouts \
    --description 'Manage ArgoCD rollouts' \
    --executable 'kubectl-argo-rollouts' \
    --kubecli-completion-provider 'kubectl_argo_rollouts'


# -----------------------------------------------------------------------------
# Setup:
# -----------------------------------------------------------------------------

# Load and override kubectl completions.
kubectl completion fish | source
complete -c kubectl -e
complete -c kubectl -n '__kubecompletions_completions_clear'
complete -c kubectl -n '__kubecompletions_completions_generate kubecompletions' -f -a '$__kubecompletions_comps'
complete -c kubectl -n '__kubecompletions_completions_generate no-order' -f -a '$__kubecompletions_comps'
complete -k -c kubectl -n '__kubecompletions_completions_generate keep-order' -f -a '$__kubecompletions_comps'

# Clear any cached completions.
__kubecompletions_completions_clear
