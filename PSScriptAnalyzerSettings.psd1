# PSScriptAnalyzer configuration for this repository's PowerShell scripts.
#
# Auto-discovered by `Invoke-ScriptAnalyzer -Path .` when run from the repo
# root (PSScriptAnalyzer reads a PSScriptAnalyzerSettings.psd1 found in the
# analyzed directory). The same file is baked into the agent image as the
# house default at /usr/local/share/powershell/PSScriptAnalyzerSettings.psd1
# (see docker/base/Dockerfile) for projects that do not ship their own.
#
# The rules below are excluded deliberately: each conflicts with an
# intentional pattern in these CLI-style scripts or is known to misfire.
@{
    ExcludeRules = @(
        # These are interactive CLI tools; Write-Host is the intended way to
        # emit coloured console output, not accidental pipeline pollution.
        'PSAvoidUsingWriteHost'

        # Command functions use shell-style kebab-case names (agent-update,
        # cc-list, ...) that mirror their .sh twins for cross-shell parity.
        # PowerShell's Verb-Noun convention does not apply to these entry points.
        'PSUseApprovedVerbs'

        # The plural-noun heuristic misfires on a verb-final 's' (e.g.
        # Test-ImageExists reads as a question, not a plural noun).
        'PSUseSingularNouns'

        # False positives for parameters consumed only inside nested functions
        # or script blocks (e.g. build-image.ps1's $ClaudeVersion/$CodexVersion).
        'PSReviewUnusedParameter'
    )
}
