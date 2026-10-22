package store

import (
	"gorm.io/gorm/clause"
)

// onConflictDoNothing builds an ON CONFLICT (cols) DO NOTHING clause, used to
// make repeated uploads idempotent rather than an error.
func onConflictDoNothing(columns ...string) clause.OnConflict {
	cols := make([]clause.Column, 0, len(columns))
	for _, c := range columns {
		cols = append(cols, clause.Column{Name: c})
	}
	return clause.OnConflict{Columns: cols, DoNothing: true}
}

// forUpdate builds a SELECT ... FOR UPDATE clause, used to serialise readers
// that are about to derive a new value from what they read.
func forUpdate() clause.Locking {
	return clause.Locking{Strength: "UPDATE"}
}
