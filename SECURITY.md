# Security Policy

Engram stores and recalls user-derived memory for host applications. Treat every stored
memory as untrusted application data, even when it was extracted by a model or written by
your own code.

## Memory injection threat model

Recalled memory is contextual data, not an instruction source. A malicious or confused user
can cause text such as "ignore previous instructions" or fake XML tags to be stored as a
memory. Engram escapes memory content and wraps recalled memories in typed delimiters before
prompt injection, but escaping is not an authorization boundary and does not make memory
content safe to execute as instructions.

Host applications should:

- Keep system and developer instructions higher priority than any recalled memory.
- Tell the model that recalled memories are context only and must not override policy,
  authorization, or tool-use rules.
- Avoid storing credentials, secrets, raw request logs, or transient task-progress text as
  memories.
- Apply application authorization before choosing a memory scope and before acting on a
  recalled fact.
- Log only operational metadata such as counts, durations, adapter names, and safe scope
  identifiers. Do not log prompts, message text, memory content, embeddings, or raw scopes
  that contain personal data.

## Scope isolation

Engram scopes are the tenancy boundary for recall. Use stable, application-owned scope
identifiers such as `user:42`, `account:7`, or another value that already passed your
application authorization checks. Do not use raw user input as a scope without validation.

The pgvector adapter and in-memory adapter filter by exact scope before recall. Prefixes such
as `user:4` and `user:42` are distinct scopes. Applications remain responsible for mapping
an authenticated user or tenant to the correct scope.

## Deletion and retention

`forget_stale` prunes old memories by scope and age. It is a retention helper, not a complete
legal-compliance workflow. If your product must support account erasure or regulatory data
subject requests, build and test an application-level erasure path for every persisted Engram
store and processed-turns store you configure.

## Reporting vulnerabilities

Please report vulnerabilities privately through GitHub Security Advisories:
https://github.com/kholdrex/engram/security/advisories/new. Include the affected Engram
version or commit, reproduction steps, and the storage/adapter configuration involved.
