# Contributing

Open an issue with the expected routing behavior, Windows version, Clash Verge / Mihomo version, and adapter types. Use fictional domains, TEST-NET addresses and placeholder node credentials in examples.

Run `npm ci`, `npm run check`, and `npm test`. For PowerShell changes also run `powershell -ExecutionPolicy Bypass -File ./tests/installer.test.ps1` on Windows. Add focused regression coverage for changed routing or restore behavior. Keep the project dependency-free and document runtime constraints.

Contributions are licensed under Apache-2.0.
