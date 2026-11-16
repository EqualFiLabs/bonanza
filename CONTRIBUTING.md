# Contributing to Bonanza

Start with the [README](README.md) for setup and the
[architecture guide](docs/architecture.md) for the protocol boundaries.
The product name is **Bonanza** and the token symbol is **BONANZA**.

## Changes

Keep changes focused and explain the problem, resulting behavior, validation,
and relevant limitations in the pull request. Use descriptive feature or fix
branches and concise Conventional Commit subjects.

For behavior changes, update the relevant [requirements](specs/requirements.md),
[design](specs/design.md), and tests together. Preserve storage layouts, selector
routing, accounting boundaries, and exact-transfer checks. Existing storage and
module hash inputs are compatibility identities rather than display names.

Run the build and checks described in the README. Build the pinned Statics
integration before tests that consume its artifacts. Report local tests,
fork execution, formal verification, and deployed validation separately;
identify skipped checks explicitly.

## Public contributions

Keep credentials, private endpoints, internal review findings, and proof execution
artifacts out of commits, pull request descriptions, and public issues. Formal
verification has only a public summary in this repository. Preserve existing
license notices and dependency pins unless the change explicitly addresses them.

Do not disclose vulnerability details in a public issue or pull request. Arrange
a private reporting channel with the maintainers before sharing sensitive findings.
