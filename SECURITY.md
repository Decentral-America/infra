# Security Policy

## Supported Versions

This repository contains infrastructure code for the DecentralChain (DCC) ecosystem.
All versions of the `main` branch are considered current.

## Reporting a Vulnerability

If you discover a security vulnerability in this repository, **do not open a public GitHub issue**.

Please report it privately via one of the following channels:

- **GitHub Private Security Advisory**: Use the [Security Advisory](../../security/advisories/new) feature in this repository.
- **Email**: Contact the security team at `info@decentralchain.io`.

### What to include

- A description of the vulnerability and its potential impact.
- Steps to reproduce (if applicable).
- Any suggested remediation if you have one.

### What to expect

- We will acknowledge receipt within **48 hours**.
- We aim to triage and respond with a preliminary assessment within **5 business days**.
- We will notify you when the vulnerability has been remediated.
- We will credit you in the fix (unless you prefer to remain anonymous).

## Security Architecture

This infra repo manages Linode server provisioning via OpenTofu and Docker-based deployments.

Key security boundaries:
- **Secrets are never stored in code** — all sensitive values are in GitHub Secrets (Tier 2) or on-server `/opt/dcc/secrets/<network>.env` files (Tier 3).
- **The infra repo is public** (required for cross-org reusable workflows on GitHub Free plan). No secrets are in the code.
- **Environments have required reviewers** for `infra-<network>-provision` environments — apply/destroy require human approval.
- **GHCR authentication** is performed per-deploy using a scoped PAT passed securely via SSH action environment variables.

## Responsible Disclosure

We follow coordinated disclosure. We ask that you give us reasonable time to fix issues before public disclosure.
