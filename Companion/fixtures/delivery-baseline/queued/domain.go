// Package queued implements a small synthetic queued-export service used by
// the Trajectory live GitHub workbench demo.
//
// An authorized user requests an export; a worker delivers it later.
// Between those moments access can be revoked. The governing policy —
// whether the send is judged against the authorization captured at queue
// time or the authorization in force at delivery time — is declared in
// .trajectory/intent.json (coordinator-owned) and mirrored by Mode.
//
// New code for the live demo, informed by the retained sample fixture in
// the Trajectory iOS workbench (WorkbenchCore fixture programs v1/v2).
// Synthetic data only; no external systems.
package queued

// Request is an export request. ActorTenant scopes the caller's identity.
type Request struct {
	ID, UserID, TenantID, ActorTenant string
}

// Access is the live permission lookup: tenant -> user -> authorized.
type Access map[string]map[string]bool

// Allowed reports current authorization for user in tenant.
func (a Access) Allowed(tenant, user string) bool { return a[tenant][user] }

// Event is an auditable delivery side effect.
type Event struct {
	Kind      string `json:"kind"`
	RequestID string `json:"request_id"`
	TenantID  string `json:"tenant_id"`
}

// Outcome is the observed result of delivering a job.
type Outcome struct {
	Status string  `json:"status"`
	Events []Event `json:"events"`
}

// AuditEnabled gates the audit-before-release constraint.
const AuditEnabled = true

// complete releases a job only after a durable audit write. An audit
// failure blocks release: the job is never exported without its audit.
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

// validRequest enforces tenant-scoped identity: the actor must belong to
// the request's tenant and every identity field must be present.
func validRequest(req Request) bool {
	return req.ID != "" && req.UserID != "" && req.TenantID != "" && req.ActorTenant == req.TenantID
}
