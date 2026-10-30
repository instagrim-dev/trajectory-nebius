package queued

// Mode names the governing authorization policy for this source tree.
// Baseline: delivery_time — the send is judged against the authorization
// in force at delivery, so a mid-queue revocation blocks delivery.
// (Candidate A switches this tree to queue_time; see intent history.)
const Mode = "delivery_time"

// Job is a queued export. Under delivery-time policy the job carries no
// permission snapshot: nothing about authorization is trusted from enqueue.
type Job struct {
	RequestID, UserID, TenantID string
}

// Enqueue authorizes the request against current access and queues it.
// Unauthorized or malformed requests are refused here, never queued.
func Enqueue(req Request, access Access) (Job, bool) {
	if !validRequest(req) || !access.Allowed(req.TenantID, req.UserID) {
		return Job{}, false
	}
	return Job{
		RequestID: req.ID, UserID: req.UserID, TenantID: req.TenantID,
	}, true
}
