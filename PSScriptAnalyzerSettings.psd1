@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive CLI output is intentional in the engine and guardrail messages.
        'PSAvoidUsingWriteHost',
        # Repository policy mandates UTF-8 without BOM (see check-markdown.ps1 and .gitattributes).
        'PSUseBOMForUnicodeEncodedFile'
    )
}
