# Security policy

## Supported versions

Pier is pre-release software. Security fixes are applied to the latest commit on
`main`; older commits and local builds are not maintained as separate versions.

## Report a vulnerability

Please use GitHub's private vulnerability reporting for this repository:

1. open the repository's **Security** tab;
2. choose **Report a vulnerability**;
3. include the affected commit, reproduction steps, impact, and any suggested
   mitigation.

If private vulnerability reporting is not enabled, contact the repository owner
privately through the contact method listed on their GitHub profile. Do not open
a public issue containing exploit details, local process data, credentials, or
other sensitive information.

You should receive an acknowledgement within seven days. Timelines for a fix and
public disclosure depend on severity and reproducibility.

## Scope

Reports are especially useful when they involve:

- unintended outbound network access;
- localhost preview navigation escaping its allowed host;
- command or argument injection;
- secrets entering process arguments or Pier's log;
- overly broad file permissions;
- destructive actions occurring without clear user confirmation.

Pier's documented security boundaries are in
[Privacy and security](docs/privacy-and-security.md).
