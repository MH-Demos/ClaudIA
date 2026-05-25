# Localization

English is the source language for ClaudIA documentation, scripts, examples, and public portal text.

## Rule

Do not prefix English files with `eng-`. Keep the current file names stable and translate only when a second language is actually added.

Recommended structure:

```text
docs/
  security.md
  costs.md
  es/
    security.md
    costs.md
  fr/
    security.md
    costs.md
```

For root-level documents, keep English at the root:

```text
README.md
How to Start.md
docs/es/README.md
docs/es/How to Start.md
```

## Configuration Locales

The [config/locales](../config/locales) folder is for synthetic data generation patterns by geography and language. It should not be used for documentation translations.

## Contribution Checklist

- Update English first.
- Add or refresh translations in `docs/<locale>` only when the translation is ready.
- Keep code comments and script output in English unless a script explicitly supports localized output.
- Keep links stable across languages whenever possible.
- Do not duplicate generated logs, credentials, or tenant-specific configuration inside translated docs.

