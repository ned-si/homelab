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
effort:

- acknowledgement within 7 days;
- a leaked credential is revoked first, then fixed in the repository;
- you are credited in the fix if you want to be.

There is no bug bounty.

## Please do not

- run active scans, fuzzing, brute-force or load tests against the live
  services behind this configuration;
- try to access data that is not yours.

Reading the repository and reporting what you find is all that is needed.
