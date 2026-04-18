# Handy Information

## Package Size Check

The size of the packages (before committing to a download) can be checked with the following command:

```bash
npm view @anthropic-ai/claude-code-win32-x64 dist.unpackedSize dist.tarball
```

Each flavor has a suffix. Derived by parsing the install script in the root package `@anthropic-ai/claude-code`.
