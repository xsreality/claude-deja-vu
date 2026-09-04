# Security

## Reporting a vulnerability

Please report security problems privately through
[GitHub's private vulnerability reporting](https://github.com/xsreality/claude-deja-vu/security/advisories/new)
rather than in a public issue.

## What this app touches

- It **reads** `~/.claude/projects/` and never writes to it.
- Browsing and searching make no network calls.
- It writes exactly one file: `~/Library/Application Support/DejaVu/insights.json`.
- **Cross-reference** is the only feature that leaves the machine. It runs the
  `claude` CLI as a subprocess, passing about 700 characters of each recent
  conversation on stdin. Nothing else is sent anywhere, and it only runs when
  you click the button.
- The app ships **unsandboxed**, because reading `~/.claude/projects` and
  spawning the `claude` CLI both require it. This also means the Mac App Store
  is not a distribution option.
- There are **no third-party dependencies** — the app is Swift plus Apple
  frameworks, so there is no transitive supply chain to audit.

## What you can verify about a release

Every release is built by
[`.github/workflows/release.yml`](.github/workflows/release.yml) on a GitHub
runner and carries a Sigstore-signed build provenance attestation:

```bash
gh attestation verify ClaudeDejaVu-0.1.2.dmg \
  --repo xsreality/claude-deja-vu \
  --signer-workflow xsreality/claude-deja-vu/.github/workflows/release.yml
```

That proves which repository, commit and workflow produced the exact bytes you
downloaded. Releases also carry `SHA256SUMS`, and the Homebrew cask pins the
DMG's SHA-256 — Homebrew refuses a download that does not match. The cask is
only bumped by a workflow that verifies the attestation first, so a
`brew install` cannot pin an unverified artifact.

Third-party GitHub Actions are pinned to commit SHAs rather than tags, and the
release job requests only the permissions it needs.

## What is not covered

The app is **signed ad-hoc, not notarised by Apple**, which is why the first
launch needs *System Settings > Privacy & Security > Open Anyway*. A Developer ID
signature and a notarisation ticket require a paid Apple Developer account.
Build provenance is the substitute offered here: it tells you where the binary
came from, which a notarisation ticket does not.
