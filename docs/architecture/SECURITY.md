# Public graph and screenshot review

Reviewed 2026-10-05 before publication.

## Export boundary

The original local Graphify graph is not published. Its documentation nodes, work-directory copies, labels, source snippets, relationship context, absolute paths, graph metadata and caches are excluded.

The public JSON contains only relative paths to existing public Swift source files / Package.swift, filename-derived labels, module names, and aggregate counts for extracted cross-file relationships. Edges whose endpoints cannot be resolved to those files are dropped. This is a lossy file-level projection, not a full symbol graph.

The explorer embeds exactly that JSON. It loads no remote scripts, fonts, analytics, or data; it uses textContent for labels and a restrictive content security policy. It makes no network requests.

## Checks

- Validated the JSON field allowlist and every node path against tracked public source files.
- Validated every edge endpoint and positive integer count.
- Searched the export for credentials, emails, personal account names, absolute home/volume paths, private IPs, and private-key material.
- Ran detect-secrets against the publication changes.
- Re-encoded screenshot PNGs without metadata and visually reviewed the masks over personal account/workspace details and terminal title/path.

These checks reduce accidental disclosure risk; they are not a formal security certification or an audit of the entire app. Public repository ownership, dependency attribution, and public project names are intentional.

To refresh this map, repeat the allowlisted projection and review before publication. Do not copy a complete local graph directory into this repository.
