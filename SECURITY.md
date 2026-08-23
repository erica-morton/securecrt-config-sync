# Security

## Sensitive configuration data

This repository must never contain SecureCRT configuration exports, session
files, host inventories, usernames, passwords, passphrases, private keys,
license files, or other user data.

The setup helpers scan shared session files for common saved-password markers
and fail closed when one is found. This is a safety check, not a proof that a
configuration is free of secrets. Review a configuration before placing it in
cloud storage and use SecureCRT's Personal Data feature for sensitive values.

## Reporting a vulnerability

Please use GitHub's private vulnerability-reporting or security-advisory
channel when available. Do not include real SecureCRT configuration files or
credentials in a public issue.
