package queued

const Mode = "queue_time"

type Job struct {
	RequestID, UserID, TenantID string
	PermissionSnapshot        bool
}

func Enqueue(req Request, access Access) (Job, bool) {
	if !validRequest(req) || !access.Allowed(req.TenantID, req.UserID) {
		return Job{}, false
	}
	return Job{
		RequestID: req.ID, UserID: req.UserID, TenantID: req.TenantID,
		PermissionSnapshot: access.Allowed(req.TenantID, req.UserID),
	}, true
}
