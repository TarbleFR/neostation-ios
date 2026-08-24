# Security Policy

Security reports for this repository should be handled privately and responsibly.

## Reporting a vulnerability

If you believe you found a security vulnerability in NeoStation iOS, **do not open a public issue with exploit details**.

Use the repository's private GitHub Security Advisory flow:

- [Report a vulnerability privately](https://github.com/TarbleFR/neostation-ios/security/advisories/new)

If GitHub's private advisory flow is unavailable, contact the iOS-port maintainer, [@TarbleFR](https://github.com/TarbleFR), through a private channel before publishing technical details.

Reports that affect only the original upstream NeoStation project should be disclosed to the upstream maintainers instead.

## Sensitive data

Contributors must never commit:

- a real `.env` file;
- `SCREENSCRAPER_DEV_ID` or `SCREENSCRAPER_DEV_PASSWORD` values;
- user passwords, API keys or session tokens;
- Apple signing certificates, provisioning profiles or private keys;
- private user data, ROMs or cloud-save contents.

ScreenScraper developer credentials are build-time inputs and should enter Dart through compile-time defines. User account credentials are runtime data and must follow the application's existing storage path.

## Contributor checklist

- Validate file paths and external inputs before use.
- Preserve platform permission boundaries and security-scoped/document access behavior.
- Treat deeplink parameters and external-emulator handoff data as untrusted input.
- Keep third-party dependencies and native code within their documented security constraints.
- Avoid logging secrets or private user data.
