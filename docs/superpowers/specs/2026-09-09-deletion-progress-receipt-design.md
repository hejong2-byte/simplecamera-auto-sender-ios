# Deletion progress and verified receipt recovery

Approved in conversation: deletion progress uses processed item counts, a percentage,
current item name and separate success/failure counts. Apply to manual iPhone deletion
and SD/USB selected-folder contents deletion. Preserve selection confirmation, root,
sibling files, security scopes, receipt protection and original files on failure.

USB progress counts immediate children (a folder is one operation); nested contents are
removed by the existing coordinated deletion. Unknown total during preflight uses an
indeterminate indicator. Never invent byte progress. Final success requires a fresh
inventory; an error reported for an item already absent must not become a false failure.

Also distinguish locally verified storage from server receipt rejection. Persist a
receipt-pending outcome; retain the local file and durable ACK job. Do not skip SHA or
assume any HTTP 409 means success. Server diagnosis requires authenticated read-only
state lookup and the currently deployed Worker source before a server fix/deployment.

Filesystem metadata must be read under the selected security scope; absent metadata
is not connection failure. Do not guess FAT32 from size or expose host backing volume
as the external provider's filesystem. No formatting is included.

Validation: regression tests on disposable files; positive/negative/partial deletion,
failure after removal, pending ACK persistence/retry, and unavailable metadata; full
iOS tests and unsigned IPA build. Physical USB/provider timing remains device testing.
