# Contributing

Thanks for helping improve SlowDNS.

## Before You Start

- Open an issue before making large or security-sensitive changes.
- Keep changes narrowly scoped.
- Do not commit production secrets, real install codes, or private backend
  implementation.

## Development Expectations

- Preserve the public installer contract in [install.sh](install.sh).
- Keep the GitHub repo limited to the public SlowDNS installer/runtime pieces.
- Do not add private license-server code to this repository.
- Prefer simple, auditable shell and Python changes over clever shortcuts.

## Testing

Before opening a pull request:

- run syntax checks relevant to the files you changed
- verify the installer flow still works from the repo root
- note any Linux-only checks you could not run locally

## Pull Requests

- Explain what changed and why.
- Call out any install-flow, service, or compatibility impact.
- Include rollback notes for risky changes.
- Keep unrelated cleanup out of the PR.

## Security Reports

Please do not use GitHub issues for vulnerabilities. Follow
[SECURITY.md](SECURITY.md) instead.
