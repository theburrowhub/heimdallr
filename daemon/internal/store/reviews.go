package store

import (
	"fmt"
	"time"
)

// Review represents a code review result stored locally.
type Review struct {
	ID          int64
	PRID        int64
	CLIUsed     string
	Summary     string
	Issues      string // JSON array
	Suggestions string // JSON array
	Severity    string
	CreatedAt   time.Time
}

// InsertReview inserts a new review record and returns its row ID.
func (s *Store) InsertReview(r *Review) (int64, error) {
	res, err := s.db.Exec(`
		INSERT INTO reviews (pr_id, cli_used, summary, issues, suggestions, severity, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, r.PRID, r.CLIUsed, r.Summary, r.Issues, r.Suggestions, r.Severity,
		r.CreatedAt.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return 0, fmt.Errorf("store: insert review: %w", err)
	}
	return res.LastInsertId()
}

// ListReviewsForPR returns all reviews for a given PR, ordered by created_at descending.
func (s *Store) ListReviewsForPR(prID int64) ([]*Review, error) {
	rows, err := s.db.Query(
		"SELECT id, pr_id, cli_used, summary, issues, suggestions, severity, created_at FROM reviews WHERE pr_id = ? ORDER BY created_at DESC",
		prID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list reviews: %w", err)
	}
	defer rows.Close()
	var reviews []*Review
	for rows.Next() {
		rev, err := scanReview(rows)
		if err != nil {
			return nil, err
		}
		reviews = append(reviews, rev)
	}
	return reviews, rows.Err()
}

// LatestReviewForPR returns the most recent review for a PR. Returns sql.ErrNoRows if none.
func (s *Store) LatestReviewForPR(prID int64) (*Review, error) {
	row := s.db.QueryRow(
		"SELECT id, pr_id, cli_used, summary, issues, suggestions, severity, created_at FROM reviews WHERE pr_id = ? ORDER BY created_at DESC LIMIT 1",
		prID,
	)
	return scanReview(row)
}

// PurgeOldReviews deletes reviews older than maxDays. No-op if maxDays == 0.
func (s *Store) PurgeOldReviews(maxDays int) error {
	if maxDays == 0 {
		return nil
	}
	_, err := s.db.Exec(
		"DELETE FROM reviews WHERE created_at < datetime('now', ?)",
		fmt.Sprintf("-%d days", maxDays),
	)
	return err
}

func scanReview(s scanner) (*Review, error) {
	var rev Review
	var createdAt string
	if err := s.Scan(&rev.ID, &rev.PRID, &rev.CLIUsed, &rev.Summary,
		&rev.Issues, &rev.Suggestions, &rev.Severity, &createdAt); err != nil {
		return nil, fmt.Errorf("store: scan review: %w", err)
	}
	rev.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	return &rev, nil
}
