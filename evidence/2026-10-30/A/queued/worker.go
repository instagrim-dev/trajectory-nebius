package queued

// Deliver sends a queued job. Queue-time policy: the send is judged against
// the permission snapshot captured at enqueue time. If the snapshot is true,
// the job delivers even if access has been revoked in the meantime. If the
// snapshot is false, delivery is blocked with access_revoked and no side-effect events.
func Deliver(job Job, actorTenant string, access Access, audit func(Event) error) Outcome {
	if job.RequestID == "" || job.UserID == "" || job.TenantID == "" {
		return Outcome{Status: "invalid_job", Events: []Event{}}
	}
	if actorTenant != job.TenantID {
		return Outcome{Status: "denied", Events: []Event{}}
	}
	if !job.PermissionSnapshot {
		return Outcome{Status: "access_revoked", Events: []Event{}}
	}
	return complete(job, audit)
}