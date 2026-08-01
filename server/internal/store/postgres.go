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

// Migrate applies every embedded SQL migration in lexical order. Each file is
// expected to be idempotent (IF NOT EXISTS), so re-running is safe.
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

	for _, name := range names {
		body, err := migrationFS.ReadFile("migrations/" + name)
		if err != nil {
			return fmt.Errorf("read %s: %w", name, err)
		}
		if err := s.db.WithContext(ctx).Exec(string(body)).Error; err != nil {
			return fmt.Errorf("apply %s: %w", name, err)
		}
		s.log.Info("migration applied", "file", name)
	}
	return nil
}
