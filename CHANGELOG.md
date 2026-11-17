# Changelog

## 1.3.2

- Keep routing enhancement active when a preferred node disappears after switching subscriptions.
- Add opt-in health-checked fallback groups for overseas nodes, alongside manual selection.
- Document configuration reload and node health behavior.

## 1.3.1

- Supervise the fallback worker and restart it after unexpected exits, with local exit diagnostics.
- Retry state/log file write errors while preserving active network monitoring.
- Record adapter readiness details and permit installation while the campus USB adapter is unplugged.

## 1.3.0

- Add an opt-in Windows fallback watcher: move domestic DIRECT to Wi-Fi on Ethernet loss and restore Ethernet after stable recovery.
- Reconcile interface settings after core reloads, verify API changes and rebuild active connections on transition.
- Add per-user background startup/install/uninstall, local state and bounded logs.

## 1.2.0

- Add opt-in strict routing with foreign-service precedence, strict TUN routing, IPv4 and rule-aware DNS.
- Add an administrator-operated adapter IPv4-only helper with preview, WhatIf, GUID-checked backup and restore.
- Document reconnecting existing applications and checking actual physical egress, including TCP and UDP.
- Preserve default rule-preservation behavior; strict mode explicitly replaces subscription policies.

## 1.1.0

- Preserve subscription rules by default; add campus domains and TUN exclusions.
- Discover domestic DNS/gateway addresses and default proxy transports to IPv4.

## 1.0.0

- Initial configurable dual-interface routing, installation and restore helpers.
