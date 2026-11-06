@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The installers are interactive scripts: they write to the console.
        'PSAvoidUsingWriteHost',
        # Internal functions of a script; the script asks before each change.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
