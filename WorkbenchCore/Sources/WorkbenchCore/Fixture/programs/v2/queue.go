package queued

const Mode = "delivery_time"

type Job struct {
	RequestID, UserID, TenantID string
}

func Enqueue(req Request, access Access) (Job, bool) {
	if !validRequest(req) || !access.Allowed(req.TenantID, req.UserID) {
		return Job{}, false
	}
	return Job{
		RequestID: req.ID, UserID: req.UserID, TenantID: req.TenantID,
	}, true
}
