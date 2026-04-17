// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tracked_issue.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TrackedIssueReview _$TrackedIssueReviewFromJson(Map<String, dynamic> json) =>
    TrackedIssueReview(
      id: (json['id'] as num).toInt(),
      issueId: (json['issue_id'] as num).toInt(),
      cliUsed: json['cli_used'] as String,
      summary: json['summary'] as String,
      triage: json['triage'] as Map<String, dynamic>,
      suggestions: json['suggestions'] as List<dynamic>,
      actionTaken: json['action_taken'] as String,
      prCreated: (json['pr_created'] as num).toInt(),
      createdAt: DateTime.parse(json['created_at'] as String),
    );

Map<String, dynamic> _$TrackedIssueReviewToJson(TrackedIssueReview instance) =>
    <String, dynamic>{
      'id': instance.id,
      'issue_id': instance.issueId,
      'cli_used': instance.cliUsed,
      'summary': instance.summary,
      'triage': instance.triage,
      'suggestions': instance.suggestions,
      'action_taken': instance.actionTaken,
      'pr_created': instance.prCreated,
      'created_at': instance.createdAt.toIso8601String(),
    };

TrackedIssue _$TrackedIssueFromJson(Map<String, dynamic> json) => TrackedIssue(
  id: (json['id'] as num).toInt(),
  githubId: (json['github_id'] as num).toInt(),
  repo: json['repo'] as String,
  number: (json['number'] as num).toInt(),
  title: json['title'] as String,
  body: json['body'] as String,
  author: json['author'] as String,
  assignees: json['assignees'] as List<dynamic>,
  labels: json['labels'] as List<dynamic>,
  state: json['state'] as String,
  createdAt: DateTime.parse(json['created_at'] as String),
  fetchedAt: DateTime.parse(json['fetched_at'] as String),
  dismissed: json['dismissed'] as bool? ?? false,
  latestReview: json['latest_review'] == null
      ? null
      : TrackedIssueReview.fromJson(
          json['latest_review'] as Map<String, dynamic>,
        ),
);

Map<String, dynamic> _$TrackedIssueToJson(TrackedIssue instance) =>
    <String, dynamic>{
      'id': instance.id,
      'github_id': instance.githubId,
      'repo': instance.repo,
      'number': instance.number,
      'title': instance.title,
      'body': instance.body,
      'author': instance.author,
      'assignees': instance.assignees,
      'labels': instance.labels,
      'state': instance.state,
      'created_at': instance.createdAt.toIso8601String(),
      'fetched_at': instance.fetchedAt.toIso8601String(),
      'dismissed': instance.dismissed,
      'latest_review': ?instance.latestReview,
    };
