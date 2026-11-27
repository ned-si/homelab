# Security policy

This repository is the configuration of a personal homelab: Kubernetes
manifests, Helm values, scripts and CI. There are no releases; only `main` is
supported, and it is what the cluster runs.

## Reporting a vulnerability

Please report privately. Do not open a public issue or pull request.

1. Preferred: GitHub private vulnerability reporting. Open the repository's
   **Security** tab and choose **Report a vulnerability**.
2. Otherwise: email `nedsi@pm.me` with "homelab security" in the subject.

Useful to include: the file and line or the setting concerned, what an attacker
could do with it, and how to reproduce it.

Things worth reporting:

- a credential, key or token committed in plaintext, in any commit;
- a workflow that could run untrusted code with repository permissions or
  leak a secret;
- a manifest or setting that exposes a service, or weakens authentication, in
  a way the repository does not intend.

## What to expect

This is maintained by one person in their spare time, so responses are best
effort, following the steps in [Handling a report](#handling-a-report).
There is no bug bounty.

## Handling a report

1. Acknowledge the report within 7 days.
2. Reproduce it and rate its severity with a CVSS v4 base score.
3. A leaked credential is revoked or rotated at its source first
   ([docs/secrets.md](docs/secrets.md#rotating-a-credential)), then removed
   from the repository.
4. Fix it on `main` through a normal pull request merged by
   `scripts/pr-merge.sh`, so `ci` runs on it. For a problem that is not
   public yet, the fix is prepared in a GitHub private security advisory and
   its temporary private fork, then pushed as that pull request when it is
   ready.
5. Publish the advisory once the fix is on `main`, crediting the reporter if
   they want to be.

What users of this repository can and cannot expect from its security:
[docs/assurance-case.md](docs/assurance-case.md#security-requirements).

## Please do not

- run active scans, fuzzing, brute-force or load tests against the live
  services behind this configuration;
- try to access data that is not yours.

Reading the repository and reporting what you find is all that is needed.
