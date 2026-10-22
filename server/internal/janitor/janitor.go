// Package janitor runs periodic housekeeping: dropping data past its
// retention period so that nothing the server holds outlives its purpose.
package janitor

import (
	"context"
	"log/slog"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// Task is one housekeeping job.
type Task struct {
	Name string
	Run  func(ctx context.Context) error
}

// Run executes every task once at start and then on each interval tick,
// until ctx is cancelled. A failing task is logged and retried next tick; it
// never stops the others.
func Run(ctx context.Context, interval time.Duration, log *slog.Logger, tasks ...Task) {
	runAll := func() {
		for _, t := range tasks {
			taskCtx, cancel := context.WithTimeout(ctx, interval/2)
			if err := t.Run(taskCtx); err != nil {
				log.Warn("housekeeping task failed", "task", t.Name, "err", err)
			}
			cancel()
		}
	}

	runAll()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			runAll()
		}
	}
}

// PurgeTask drops expired database rows.
func PurgeTask(st *store.Store, policy store.RetentionPolicy, log *slog.Logger) Task {
	return Task{
		Name: "purge_expired",
		Run: func(ctx context.Context) error {
			rep, err := st.PurgeExpired(ctx, policy)
			if err != nil {
				return err
			}
			if rep != (store.PurgeReport{}) {
				log.Info("expired data purged",
					"undelivered", rep.UndeliveredDropped,
					"delivered", rep.DeliveredDropped,
					"sessions", rep.SessionsDropped,
					"prekeys", rep.PreKeysDropped,
					"sender_keys", rep.SenderKeysDropped,
					"group_bodies", rep.GroupBodiesDropped)
			}
			return nil
		},
	}
}
