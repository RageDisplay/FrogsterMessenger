// Package store owns persistence. It exposes narrow, intention-revealing
// operations rather than a generic ORM handle, so that invariants such as
// atomic prekey consumption live in one place.
package store

import (
	"context"
	"embed"
	"fmt"
	"log/slog"
	"sort"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	gormlogger "gorm.io/gorm/logger"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

// Store is the database facade used by the rest of the server.
type Store struct {
	db  *gorm.DB
	log *slog.Logger
}

// Open connects to PostgreSQL and configures the connection pool.
func Open(ctx context.Context, dsn string, log *slog.Logger) (*Store, error) {
	// GORM's own logging is kept at Error level: query logs would echo bound
	// parameters, which for this schema means ciphertext.
	gdb, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
		Logger:                 gormlogger.Default.LogMode(gormlogger.Error),
		SkipDefaultTransaction: true,
	})
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}

	sqlDB, err := gdb.DB()
	if err != nil {
		return nil, fmt.Errorf("get sql.DB: %w", err)
	}
	sqlDB.SetMaxOpenConns(25)
	sqlDB.SetMaxIdleConns(10)
	sqlDB.SetConnMaxLifetime(time.Hour)

	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := sqlDB.PingContext(pingCtx); err != nil {
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	return &Store{db: gdb, log: log}, nil
}

// DB exposes the underlying handle for packages that need ad-hoc queries.
func (s *Store) DB() *gorm.DB { return s.db }

// Close releases the connection pool.
func (s *Store) Close() error {
	sqlDB, err := s.db.DB()
	if err != nil {
		return err
	}
	return sqlDB.Close()
}

// migrationLockID is the advisory lock key serialising migrations, so two
// instances starting together cannot apply the same file twice.
const migrationLockID = 0x46524F47 // "FROG"

// Migrate applies the embedded SQL migrations that have not run yet, in
// lexical order, recording each in schema_migrations.
//
// Everything runs in one transaction under an advisory lock: PostgreSQL DDL is
// transactional, so a failing file leaves the schema exactly as it was rather
// than half-migrated. The files are still written idempotently (IF NOT
// EXISTS), because databases created before schema_migrations existed run
// 0001 and 0002 once more on the first upgrade.
func (s *Store) Migrate(ctx context.Context) error {
	entries, err := migrationFS.ReadDir("migrations")
	if err != nil {
		return fmt.Errorf("read migrations: %w", err)
	}

	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Exec("SELECT pg_advisory_xact_lock(?)", migrationLockID).Error; err != nil {
			return fmt.Errorf("lock migrations: %w", err)
		}
		if err := tx.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
			name       TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`).Error; err != nil {
			return fmt.Errorf("create schema_migrations: %w", err)
		}

		var applied []string
		if err := tx.Raw("SELECT name FROM schema_migrations").Scan(&applied).Error; err != nil {
			return fmt.Errorf("read schema_migrations: %w", err)
		}
		done := make(map[string]bool, len(applied))
		for _, n := range applied {
			done[n] = true
		}

		for _, name := range names {
			if done[name] {
				continue
			}
			body, err := migrationFS.ReadFile("migrations/" + name)
			if err != nil {
				return fmt.Errorf("read %s: %w", name, err)
			}
			if err := tx.Exec(string(body)).Error; err != nil {
				return fmt.Errorf("apply %s: %w", name, err)
			}
			if err := tx.Exec("INSERT INTO schema_migrations (name) VALUES (?)", name).Error; err != nil {
				return fmt.Errorf("record %s: %w", name, err)
			}
			s.log.Info("migration applied", "file", name)
		}
		return nil
	})
}

// Ping checks that the database answers, for readiness probes.
func (s *Store) Ping(ctx context.Context) error {
	sqlDB, err := s.db.DB()
	if err != nil {
		return err
	}
	return sqlDB.PingContext(ctx)
}
