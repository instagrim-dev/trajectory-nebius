package queued

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
