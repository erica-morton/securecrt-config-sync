@{
    Severity = @(
        'Error'
        'Warning'
    )

    # These scripts are interactive installers rather than reusable cmdlets.
    # Direct status output is intentional, and their internal mutation helpers
    # are covered by integration tests instead of exposing -WhatIf contracts.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
