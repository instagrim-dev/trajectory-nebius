// Independent oracle for the queued-export demo. COORDINATOR-OWNED:
// the candidate generator must not edit this file (the companion rejects
// any generation touching it). Policy-parameterized tests read the
// declared answer from ../../.trajectory/intent.json; shared-constraint
// tests hold under either answer.
package queued

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func intentAnswer(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller unavailable")
	}
	raw, err := os.ReadFile(filepath.Join(filepath.Dir(file), "..", ".trajectory", "intent.json"))
	if err != nil {
		t.Fatalf("read intent manifest: %v", err)
	}
	var manifest struct {
		Answer string `json:"answer"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse intent manifest: %v", err)
	}
	if manifest.Answer != "queue_time" && manifest.Answer != "delivery_time" {
		t.Fatalf("unknown declared answer %q", manifest.Answer)
	}
	return manifest.Answer
}

func okAudit(Event) error { return nil }

// TestOwnerIntent binds source to declared intent: Mode mirrors the
// manifest answer, and the revoked_after_enqueue outcome follows it.
func TestOwnerIntent(t *testing.T) {
	answer := intentAnswer(t)
	if (Mode == "queue_time") != (answer == "queue_time") {
		t.Fatalf("Mode %q disagrees with declared answer %q", Mode, answer)
	}
	access := Access{"acme": {"ana": true}}
	job, ok := Enqueue(Request{ID: "r1", UserID: "ana", TenantID: "acme", ActorTenant: "acme"}, access)
	if !ok {
		t.Fatal("authorized enqueue refused")
	}
	access["acme"]["ana"] = false // revoke between queue and delivery
	got := Deliver(job, "acme", access, okAudit)
	want := "access_revoked"
	if answer == "queue_time" {
		want = "exported"
	}
	if got.Status != want {
		t.Fatalf("revoked_after_enqueue = %q, want %q under %q", got.Status, want, answer)
	}
}

// TestRevokedAccess is the consequential scenario: request, revoke, process.
func TestRevokedAccess(t *testing.T) {
	answer := intentAnswer(t)
	access := Access{"acme": {"ana": true}}
	job, ok := Enqueue(Request{ID: "r1", UserID: "ana", TenantID: "acme", ActorTenant: "acme"}, access)
	if !ok {
		t.Fatal("authorized enqueue refused")
	}
	access["acme"]["ana"] = false
	got := Deliver(job, "acme", access, okAudit)
	if answer == "queue_time" && got.Status != "exported" {
		t.Fatalf("queue_time must honor the enqueue snapshot, got %q", got.Status)
	}
	if answer == "delivery_time" && got.Status != "access_revoked" {
		t.Fatalf("delivery_time must block after revocation, got %q", got.Status)
	}
	if answer == "delivery_time" && len(got.Events) != 0 {
		t.Fatalf("blocked delivery must leave no events, got %+v", got.Events)
	}
}

// TestActiveAccess: authorized throughout delivers with audit then release.
func TestActiveAccess(t *testing.T) {
	access := Access{"acme": {"ana": true}}
	job, ok := Enqueue(Request{ID: "r2", UserID: "ana", TenantID: "acme", ActorTenant: "acme"}, access)
	if !ok {
		t.Fatal("authorized enqueue refused")
	}
	got := Deliver(job, "acme", access, okAudit)
	if got.Status != "exported" {
		t.Fatalf("active access must export, got %q", got.Status)
	}
	if len(got.Events) != 2 || got.Events[0].Kind != "audit" || got.Events[1].Kind != "release" {
		t.Fatalf("expected audit+release events, got %+v", got.Events)
	}
}

// TestAuditBeforeRelease: no release event may precede the audit event.
func TestAuditBeforeRelease(t *testing.T) {
	access := Access{"acme": {"ana": true}}
	job, ok := Enqueue(Request{ID: "r3", UserID: "ana", TenantID: "acme", ActorTenant: "acme"}, access)
	if !ok {
		t.Fatal("authorized enqueue refused")
	}
	var order []string
	got := Deliver(job, "acme", access, func(e Event) error {
		order = append(order, e.Kind)
		return nil
	})
	if got.Status != "exported" {
		t.Fatalf("expected export, got %q", got.Status)
	}
	if len(order) != 1 || order[0] != "audit" {
		t.Fatalf("audit must commit exactly once before release, got %v", order)
	}
}

// TestAuditFailure: an audit write failure blocks release entirely.
func TestAuditFailure(t *testing.T) {
	access := Access{"acme": {"ana": true}}
	job, ok := Enqueue(Request{ID: "r4", UserID: "ana", TenantID: "acme", ActorTenant: "acme"}, access)
	if !ok {
		t.Fatal("authorized enqueue refused")
	}
	badAudit := func(Event) error { return errAuditDown }
	got := Deliver(job, "acme", access, badAudit)
	if got.Status != "audit_blocked" {
		t.Fatalf("audit failure must block release, got %q", got.Status)
	}
	for _, e := range got.Events {
		if e.Kind == "release" {
			t.Fatalf("release must not occur when audit fails: %+v", got.Events)
		}
	}
}

// TestTenantIsolation: cross-tenant delivery is denied with no events.
func TestTenantIsolation(t *testing.T) {
	access := Access{"acme": {"ana": true}, "other": {"ana": true}}
	job, ok := Enqueue(Request{ID: "r5", UserID: "ana", TenantID: "acme", ActorTenant: "acme"}, access)
	if !ok {
		t.Fatal("authorized enqueue refused")
	}
	got := Deliver(job, "other", access, okAudit)
	if got.Status != "denied" {
		t.Fatalf("cross-tenant delivery must be denied, got %q", got.Status)
	}
	if len(got.Events) != 0 {
		t.Fatalf("denied delivery must leave no events, got %+v", got.Events)
	}
}

// TestQueueDenial: unauthorized enqueue is refused, never queued.
func TestQueueDenial(t *testing.T) {
	access := Access{"acme": {"ana": false}}
	if _, ok := Enqueue(Request{ID: "r6", UserID: "ana", TenantID: "acme", ActorTenant: "acme"}, access); ok {
		t.Fatal("unauthorized enqueue must be refused")
	}
}

// TestTenantLookup: actor identity is tenant-scoped at enqueue.
func TestTenantLookup(t *testing.T) {
	access := Access{"acme": {"ana": true}}
	if _, ok := Enqueue(Request{ID: "r7", UserID: "ana", TenantID: "acme", ActorTenant: "other"}, access); ok {
		t.Fatal("cross-tenant actor must be refused at enqueue")
	}
}

// TestInvalidJob: malformed jobs are rejected without side effects.
func TestInvalidJob(t *testing.T) {
	access := Access{"acme": {"ana": true}}
	got := Deliver(Job{}, "acme", access, okAudit)
	if got.Status != "invalid_job" {
		t.Fatalf("empty job must be invalid_job, got %q", got.Status)
	}
	if len(got.Events) != 0 {
		t.Fatalf("invalid job must leave no events, got %+v", got.Events)
	}
}
