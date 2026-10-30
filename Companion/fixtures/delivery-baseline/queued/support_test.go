package queued

import "errors"

// errAuditDown simulates a durable audit write failure.
var errAuditDown = errors.New("audit store unavailable")
