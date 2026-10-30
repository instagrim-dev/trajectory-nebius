// Command exportdemo runs the visible queued-export scenario: an
// authorized request is enqueued, access is revoked mid-queue, then the
// worker processes the job. The printed outcome exposes the governing
// policy: queue_time exports on the enqueue snapshot, delivery_time
// blocks with access_revoked and no events.
package main

import (
	"fmt"
	"os"

	"github.com/instagrim-dev/trajectory-live-demo/queued"
)

func main() {
	access := queued.Access{"acme": {"ana": true}}
	fmt.Println("request: ana@acme asks for export r1 (authorized)")
	job, ok := queued.Enqueue(queued.Request{ID: "r1", UserID: "ana", TenantID: "acme", ActorTenant: "acme"}, access)
	if !ok {
		fmt.Println("enqueue: refused")
		os.Exit(1)
	}
	fmt.Printf("enqueue: queued under policy %q\n", queued.Mode)
	access["acme"]["ana"] = false
	fmt.Println("revoke: ana@acme access revoked while r1 is queued")
	out := queued.Deliver(job, "acme", access, func(e queued.Event) error {
		fmt.Printf("audit: durable write %s for %s\n", e.Kind, e.RequestID)
		return nil
	})
	fmt.Printf("process: status=%s events=%d\n", out.Status, len(out.Events))
	for _, e := range out.Events {
		fmt.Printf("event: %s %s\n", e.Kind, e.RequestID)
	}
}
