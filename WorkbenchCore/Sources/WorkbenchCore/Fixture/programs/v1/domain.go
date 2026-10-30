// Synthetic queued-export domain. No external data is released.
package queued

type Request struct {
	ID, UserID, TenantID, ActorTenant string
}

type Access map[string]map[string]bool

func (a Access) Allowed(tenant, user string) bool { return a[tenant][user] }

type Event struct {
	Kind      string `json:"kind"`
	RequestID string `json:"request_id"`
	TenantID  string `json:"tenant_id"`
}

type Outcome struct {
	Status string  `json:"status"`
	Events []Event `json:"events"`
}

const AuditEnabled = true

func complete(job Job, audit func(Event) error) Outcome {
	events := []Event{}
	if AuditEnabled {
		event := Event{Kind: "audit", RequestID: job.RequestID, TenantID: job.TenantID}
		if err := audit(event); err != nil {
			return Outcome{Status: "audit_blocked", Events: events}
		}
		events = append(events, event)
	}
	events = append(events, Event{Kind: "release", RequestID: job.RequestID, TenantID: job.TenantID})
	return Outcome{Status: "exported", Events: events}
}

func validRequest(req Request) bool {
	return req.ID != "" && req.UserID != "" && req.TenantID != "" && req.ActorTenant == req.TenantID
}
