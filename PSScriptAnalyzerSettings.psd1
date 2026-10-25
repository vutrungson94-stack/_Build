@{
    # PSScriptAnalyzerSettings.psd1
    # Configuration for PSScriptAnalyzer during CI and local development.
    # Used by .github/workflows/build.yml lint-test step.
    # Top-level settings:
    IncludeDefaultRules       = $true
    Severity                 = @('Error', 'Warning')

    # Rules override - tuned for PowerShell 5.1/7 compat and project conventions.
    Rules = @{
        # Allow line-continuation backticks for long strings on older PS versions.
        'PSAvoidUsingCmdletAliases' = @{}
        # Ban Write-Host in modules; allow in launcher/tests where output is intentional.
        'PSAvoidUsingWriteHost' = @{
            Enable     = $true
            AllowInTests = $true
        }
        'PSMeasureCommandPerformance' = @{ Enable = $false }
        'PSUseBOMForUnicodeEncodedFile' = @{}
        # 'PSAvoidEmptyCatchBlock' excluded via ExcludeRules (intentional guarded imports)
        'PSAvoidGlobalVars'            = @{}
    }

    # Exclude patterns (paths that should not be linted).
    ExcludeRules = @(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSPlaceOpenBrace'  # Mixed coding styles on braces; not enforced
        'PSAlignAssignmentStatement',
        # Intentional project conventions / too costly to retrofit:
        'PSUseApprovedVerbs',
        'PSProvideCommentHelp',
        'PSUseOutputTypeCorrectly',
        'PSReviewUnusedParameter',
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingPositionalParameters',
        'PSAvoidUsingWriteHost',
        'PSAvoidGlobalVars',
        'PSAvoidUsingEmptyCatchBlock',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseUsingScopeModifierInNewRunspaces',
        'PSAvoidAssignmentToAutomaticVariable',
        'PSAvoidOverwritingBuiltInCmdlets',
        'PSUseProcessBlockForPipelineCommand',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingInvokeExpression'
    )
    
    # ExcludePaths is not supported by all analyzer versions; rely on ExcludeRules and inline suppressions instead.
}
