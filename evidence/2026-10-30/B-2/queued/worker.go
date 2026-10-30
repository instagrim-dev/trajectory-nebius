package queued

// Deliver sends a queued job. Delivery-time policy: the send is judged against
// the authorization in force at send (revoked access -> access_revoked, no events).
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