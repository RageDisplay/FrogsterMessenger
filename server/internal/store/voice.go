package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/storagecrypto"
)

// MaxVoiceChannels bounds the channels of one group.
const MaxVoiceChannels = 10

// ErrTooManyChannels is returned when a group has MaxVoiceChannels already.
var ErrTooManyChannels = errors.New("too many voice channels")

// VoiceChannel is a voice channel of a cloud group, name opened.
type VoiceChannel struct {
	ID        uuid.UUID
	ChatID    uuid.UUID
	Name      string
	Position  int
	CreatedAt time.Time
}

type voiceChannelRow struct {
	ID        uuid.UUID `gorm:"type:uuid;primaryKey"`
	ChatID    uuid.UUID `gorm:"type:uuid"`
	Name      []byte
	Position  int
	CreatedAt time.Time
}

func (voiceChannelRow) TableName() string { return "voice_channels" }

func voicePurpose(channelID uuid.UUID) string {
	return storagecrypto.PurposeVoiceChannel + channelID.String()
}

func (s *Store) openChannel(row *voiceChannelRow) (VoiceChannel, error) {
	name, err := s.sealer.Open(row.ChatID, voicePurpose(row.ID), 0, row.Name)
	if err != nil {
		return VoiceChannel{}, fmt.Errorf("open voice channel name: %w", err)
	}
	return VoiceChannel{ID: row.ID, ChatID: row.ChatID, Name: string(name), Position: row.Position, CreatedAt: row.CreatedAt}, nil
}

// VoiceChannels lists a group's channels in their order.
func (s *Store) VoiceChannels(ctx context.Context, chatID uuid.UUID) ([]VoiceChannel, error) {
	if s.sealer == nil {
		return nil, ErrNoStorageKey
	}
	var rows []voiceChannelRow
	if err := s.db.WithContext(ctx).Where("chat_id = ?", chatID).
		Order("position, created_at").Find(&rows).Error; err != nil {
		return nil, fmt.Errorf("voice channels: %w", err)
	}
	out := make([]VoiceChannel, 0, len(rows))
	for i := range rows {
		ch, err := s.openChannel(&rows[i])
		if err != nil {
			return nil, err
		}
		out = append(out, ch)
	}
	return out, nil
}

// VoiceChannel loads one channel of a group, or ErrNotFound.
func (s *Store) VoiceChannel(ctx context.Context, chatID, channelID uuid.UUID) (*VoiceChannel, error) {
	if s.sealer == nil {
		return nil, ErrNoStorageKey
	}
	var row voiceChannelRow
	err := s.db.WithContext(ctx).Where("id = ? AND chat_id = ?", channelID, chatID).Take(&row).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("voice channel: %w", err)
	}
	ch, err := s.openChannel(&row)
	return &ch, err
}

// CreateVoiceChannel adds a channel at the end of a group's list.
func (s *Store) CreateVoiceChannel(ctx context.Context, chatID uuid.UUID, name string) (*VoiceChannel, error) {
	if s.sealer == nil {
		return nil, ErrNoStorageKey
	}
	row := voiceChannelRow{ID: uuid.New(), ChatID: chatID, CreatedAt: time.Now()}
	sealed, err := s.sealer.Seal(chatID, voicePurpose(row.ID), 0, []byte(name))
	if err != nil {
		return nil, fmt.Errorf("seal voice channel name: %w", err)
	}
	row.Name = sealed
	err = s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// Under the chat's lock, so two admins at once cannot both get
		// the last free place.
		if err := tx.Clauses(forUpdate()).First(&models.Chat{}, "id = ?", chatID).Error; err != nil {
			return fmt.Errorf("lock chat: %w", err)
		}
		var count int64
		var last struct{ Max *int }
		if err := tx.Model(&voiceChannelRow{}).Where("chat_id = ?", chatID).Count(&count).Error; err != nil {
			return err
		}
		if count >= MaxVoiceChannels {
			return ErrTooManyChannels
		}
		if err := tx.Model(&voiceChannelRow{}).Select("MAX(position) AS max").
			Where("chat_id = ?", chatID).Scan(&last).Error; err != nil {
			return err
		}
		if last.Max != nil {
			row.Position = *last.Max + 1
		}
		return tx.Create(&row).Error
	})
	if err != nil {
		return nil, err
	}
	return &VoiceChannel{ID: row.ID, ChatID: chatID, Name: name, Position: row.Position, CreatedAt: row.CreatedAt}, nil
}

// RenameVoiceChannel gives a channel a new name.
func (s *Store) RenameVoiceChannel(ctx context.Context, chatID, channelID uuid.UUID, name string) error {
	if s.sealer == nil {
		return ErrNoStorageKey
	}
	sealed, err := s.sealer.Seal(chatID, voicePurpose(channelID), 0, []byte(name))
	if err != nil {
		return fmt.Errorf("seal voice channel name: %w", err)
	}
	res := s.db.WithContext(ctx).Model(&voiceChannelRow{}).
		Where("id = ? AND chat_id = ?", channelID, chatID).Update("name", sealed)
	if res.Error != nil {
		return fmt.Errorf("rename voice channel: %w", res.Error)
	}
	if res.RowsAffected == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteVoiceChannel removes a channel.
func (s *Store) DeleteVoiceChannel(ctx context.Context, chatID, channelID uuid.UUID) error {
	res := s.db.WithContext(ctx).Where("id = ? AND chat_id = ?", channelID, chatID).Delete(&voiceChannelRow{})
	if res.Error != nil {
		return fmt.Errorf("delete voice channel: %w", res.Error)
	}
	if res.RowsAffected == 0 {
		return ErrNotFound
	}
	return nil
}
