package queued

// Deliver sends a queued job. Delivery-time policy: current access is
// re-checked at send, so access revoked after enqueue refuses delivery
// with status access_revoked and no side-effect events.
func Deliver(job Job, actorTenant string, access Access, audit func(Event) error) Outcome {
	if job.RequestID == "" || job.UserID == "" || job.TenantID == "" {
		return Outcome{Status: "invalid_job", Events: []Event{}}
	}
	if actorTenant != job.TenantID {
		return Outcome{Status: "denied", Events: []Event{}}
	}
	if !access.Allowed(job.TenantID, job.UserID) {
		return Outcome{Status: "access_revoked", Events: []Event{}}
	}
	return complete(job, audit)
}
