CREATE TABLE "accounts" (
  "name" TEXT NOT NULL,
  "slug" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "id" TEXT NOT NULL,
  "plan" TEXT,
  "stripe_customer_id" TEXT,
  "stripe_subscription_id" TEXT,
  PRIMARY KEY ("id")
);

CREATE TABLE "activity_entries" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "environment" TEXT,
  "resource" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "actor" TEXT NOT NULL,
  "summary" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "agent_mailbox" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "agent_id" TEXT NOT NULL,
  "message_id" TEXT NOT NULL,
  "delivery_ref" TEXT NOT NULL,
  "event" TEXT NOT NULL,
  "state" TEXT NOT NULL DEFAULT 'queued',
  "generation" TEXT,
  "claimed_at" TEXT,
  "consumed_at" TEXT,
  "finished_at" TEXT,
  "diagnostic" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "send_now" INTEGER,
  FOREIGN KEY ("agent_id") REFERENCES "agents" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("message_id") REFERENCES "conversation_messages" ("id") ON DELETE CASCADE
);

CREATE TABLE "agent_model_settings" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "role" TEXT NOT NULL,
  "provider" TEXT NOT NULL,
  "model" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "user_id" INTEGER NOT NULL,
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE
);

CREATE TABLE "agent_restarts" (
  "id" TEXT NOT NULL,
  "agent_id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "reason" TEXT NOT NULL,
  "resolved_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("agent_id") REFERENCES "agents" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "agent_turns" (
  "id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "agent_id" TEXT NOT NULL,
  "story_id" INTEGER,
  "provider" TEXT,
  "model" TEXT,
  "input_tokens" INTEGER,
  "output_tokens" INTEGER,
  "cache_read_tokens" INTEGER,
  "cache_write_tokens" INTEGER,
  "inserted_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("agent_id") REFERENCES "agents" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE SET NULL
);

CREATE TABLE "agents" (
  "id" TEXT NOT NULL,
  "engine" TEXT NOT NULL,
  "provider" TEXT NOT NULL,
  "working_copy" TEXT NOT NULL,
  "config_dir" TEXT,
  "os_pid" INTEGER,
  "status" TEXT NOT NULL,
  "working_copy_id" TEXT,
  "project_id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "role" TEXT NOT NULL,
  "os_boot_id" TEXT,
  "model" TEXT,
  "tools" TEXT,
  "continuous" INTEGER NOT NULL DEFAULT 0,
  "tasks" TEXT NOT NULL DEFAULT '[]',
  "turn_started_at" TEXT,
  "declined_offer" TEXT,
  "declined_offer_at" TEXT,
  "declined_offer_count" INTEGER,
  "stopped_reason" TEXT,
  "provider_refusal" TEXT,
  "provider_refused_at" TEXT,
  "provider_retry_at" TEXT,
  "off_at" TEXT,
  "off_by" TEXT,
  "off_reason" TEXT,
  "retired_at" TEXT,
  "retired_by" TEXT,
  "retired_reason" TEXT,
  "story_id" INTEGER,
  "epic_id" TEXT,
  "issue_id" TEXT,
  "team_free_at" TEXT,
  "mailbox_generation" TEXT,
  "engine_session_id" TEXT,
  "git_rewrite_at" TEXT,
  "current_tool" TEXT,
  "waiting_since" TEXT,
  "transcript_path" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("epic_id") REFERENCES "epics" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("issue_id") REFERENCES "issues" ("id") ON DELETE SET NULL
);

CREATE TABLE "analysis_run_waiters" (
  "run_id" INTEGER NOT NULL,
  "agent_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  FOREIGN KEY ("run_id") REFERENCES "analysis_runs" ("id") ON DELETE CASCADE
);

CREATE TABLE "analysis_runs" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "source" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "args" TEXT,
  "stats" TEXT,
  "output" TEXT,
  "exit_status" INTEGER,
  "started_at" TEXT NOT NULL,
  "finished_at" TEXT,
  "project_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "working_copy_id" TEXT,
  "requested_by" TEXT,
  "start_commit" TEXT,
  "start_tree_dirty" INTEGER,
  "completed_commit" TEXT,
  "began_at" TEXT,
  "requester_agent_id" TEXT,
  "orphaned" INTEGER NOT NULL,
  "settled" TEXT,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE CASCADE
);

CREATE TABLE "app_restarts" (
  "id" TEXT NOT NULL,
  "working_copy_id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "reason" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "bdd_rules" (
  "id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "story_id" INTEGER NOT NULL,
  "statement" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE CASCADE
);

CREATE TABLE "capability_gaps" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "role" TEXT NOT NULL,
  "capability" TEXT NOT NULL,
  "occurrences" INTEGER NOT NULL,
  "issue_id" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "detail" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("issue_id") REFERENCES "issues" ("id") ON DELETE SET NULL
);

CREATE TABLE "client_users" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "email" TEXT,
  "oauth_token" BLOB,
  "oauth_refresh_token" BLOB,
  "oauth_expires_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL
);

CREATE TABLE "completion_handoffs" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "working_copy_id" TEXT NOT NULL,
  "owner_agent_id" TEXT NOT NULL,
  "assigned_by_agent_id" TEXT NOT NULL,
  "task_id" TEXT NOT NULL,
  "identity" TEXT NOT NULL,
  "artifact_paths" TEXT NOT NULL,
  "reviewed_base" TEXT NOT NULL,
  "reviewed_diff" TEXT NOT NULL,
  "purpose" TEXT NOT NULL,
  "authorship" TEXT NOT NULL DEFAULT 'unknown',
  "next_action" TEXT NOT NULL,
  "artifact_sha" TEXT,
  "parent_commit" TEXT,
  "parent_gitlink" TEXT,
  "verification" TEXT,
  "status" TEXT NOT NULL DEFAULT 'assigned',
  "delivery_state" TEXT NOT NULL DEFAULT 'pending',
  "delivery_error" TEXT,
  "completed_at" TEXT,
  "acknowledged_at" TEXT,
  "acknowledged_by_agent_id" TEXT,
  "acknowledgement" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id")
);

CREATE TABLE "component_tags" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "components" (
  "name" TEXT NOT NULL,
  "type" TEXT,
  "module_name" TEXT NOT NULL,
  "description" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "component_status" TEXT,
  "id" TEXT NOT NULL,
  "parent_component_id" TEXT,
  "project_id" TEXT NOT NULL,
  "synced_at" TEXT,
  "account_id" TEXT NOT NULL,
  "files_changed_at" TEXT,
  "last_analyzed_at" TEXT,
  "provenance" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("parent_component_id") REFERENCES "components" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE
);

CREATE TABLE "content_admin" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "raw_content" TEXT,
  "processed_content" TEXT,
  "parse_status" TEXT NOT NULL,
  "parse_errors" TEXT,
  "metadata" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE
);

CREATE TABLE "content_images" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "key" TEXT NOT NULL,
  "content_hash" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "content_snapshots" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "raw_content" TEXT,
  "processed_content" TEXT,
  "parse_status" TEXT NOT NULL,
  "parse_errors" TEXT,
  "metadata" TEXT,
  "project_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "content_tags" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "content_id" INTEGER NOT NULL,
  "tag_id" INTEGER NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("content_id") REFERENCES "contents" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("tag_id") REFERENCES "tags" ("id") ON DELETE CASCADE
);

CREATE TABLE "contents" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "slug" TEXT NOT NULL,
  "content_type" TEXT NOT NULL,
  "processed_content" TEXT,
  "protected" INTEGER NOT NULL DEFAULT 0,
  "publish_at" TEXT,
  "expires_at" TEXT,
  "meta_title" TEXT,
  "meta_description" TEXT,
  "og_image" TEXT,
  "og_title" TEXT,
  "og_description" TEXT,
  "metadata" TEXT NOT NULL DEFAULT '{}',
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "title" TEXT
);

CREATE TABLE "conversation_checkpoints" (
  "id" TEXT NOT NULL,
  "conversation_id" TEXT NOT NULL,
  "messages" TEXT NOT NULL,
  "through_message_id" TEXT,
  "turn" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("conversation_id") REFERENCES "conversations" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("through_message_id") REFERENCES "conversation_messages" ("id") ON DELETE SET NULL
);

CREATE TABLE "conversation_messages" (
  "id" TEXT NOT NULL,
  "conversation_id" TEXT NOT NULL,
  "role" TEXT NOT NULL,
  "sender_id" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "agent_role" TEXT,
  "content" TEXT NOT NULL,
  "tool_calls" TEXT,
  "tool_call_id" TEXT,
  "origin" TEXT,
  "tool_failed" INTEGER,
  "delivery" TEXT,
  "delivery_ref" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("conversation_id") REFERENCES "conversations" ("id") ON DELETE CASCADE
);

CREATE TABLE "conversation_reads" (
  "id" TEXT NOT NULL,
  "user_id" INTEGER NOT NULL,
  "conversation_id" TEXT NOT NULL,
  "last_read_at" TEXT,
  "marked_unread" INTEGER NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("conversation_id") REFERENCES "conversations" ("id") ON DELETE CASCADE
);

CREATE TABLE "conversations" (
  "id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "end_user_id" TEXT,
  "end_user_email" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "read" INTEGER NOT NULL DEFAULT 1,
  "status" TEXT NOT NULL DEFAULT 'open',
  "session_external_id" TEXT,
  "type" TEXT NOT NULL,
  "name" TEXT,
  "agent_id" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("agent_id") REFERENCES "agents" ("id") ON DELETE SET NULL
);

CREATE TABLE "criteria" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "description" TEXT NOT NULL,
  "verified" INTEGER NOT NULL DEFAULT 0,
  "verified_at" TEXT,
  "story_id" INTEGER NOT NULL,
  "project_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "rule_id" TEXT,
  "body" TEXT,
  "kind" TEXT,
  "spec_path" TEXT,
  "number" INTEGER,
  "retired_at" TEXT,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("rule_id") REFERENCES "bdd_rules" ("id") ON DELETE SET NULL
);

CREATE TABLE "dependencies" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "source_component_id" TEXT NOT NULL,
  "target_component_id" TEXT NOT NULL,
  "provenance" TEXT,
  "in_code" INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY ("source_component_id") REFERENCES "components" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("target_component_id") REFERENCES "components" ("id") ON DELETE CASCADE
);

CREATE TABLE "deploys" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "project_id" TEXT NOT NULL,
  "story_id" INTEGER NOT NULL,
  "environment" TEXT NOT NULL,
  "commit_sha" TEXT,
  "version" TEXT,
  "health_verified_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE CASCADE
);

CREATE TABLE "devices" (
  "id" TEXT NOT NULL,
  "hostname" TEXT,
  "label" TEXT,
  "kind" TEXT NOT NULL,
  "account_id" TEXT,
  "last_seen_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "load" TEXT,
  "load_reported_at" TEXT,
  "preview_tunnel_id" TEXT,
  "preview_tunnel_secret" BLOB,
  "provider" TEXT,
  "token_hash" TEXT,
  "token_last_used_at" TEXT,
  "last_up_at" TEXT,
  "token_revoked_at" TEXT,
  "fire_routine_id" TEXT,
  "fire_token" BLOB,
  PRIMARY KEY ("id")
);

CREATE TABLE "doc_embeddings" (
  "id" TEXT NOT NULL,
  "project_id" TEXT,
  "source" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "chunk_index" INTEGER NOT NULL DEFAULT 0,
  "content" TEXT NOT NULL,
  "content_hash" TEXT NOT NULL,
  "file_hash" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "embedding" BLOB,
  "package" TEXT,
  "version" TEXT,
  "model" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "doc_packages" (
  "id" TEXT NOT NULL,
  "package" TEXT NOT NULL,
  "version" TEXT NOT NULL,
  "model" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "chunk_count" INTEGER,
  "error" TEXT,
  "embedded_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "attempts" INTEGER,
  PRIMARY KEY ("id")
);

CREATE TABLE "email_attachments" (
  "id" TEXT NOT NULL,
  "provider_attachment_id" TEXT,
  "filename" TEXT,
  "content_type" TEXT,
  "content_disposition" TEXT,
  "content_id" TEXT,
  "size" INTEGER,
  "s3_key" TEXT NOT NULL,
  "email_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("email_id") REFERENCES "emails" ("id") ON DELETE CASCADE
);

CREATE TABLE "emails" (
  "id" TEXT NOT NULL,
  "direction" TEXT NOT NULL,
  "from_address" TEXT,
  "to_address" TEXT,
  "correspondent" TEXT,
  "subject" TEXT,
  "body_text" TEXT,
  "body_html" TEXT,
  "provider_id" TEXT,
  "message_id" TEXT,
  "in_reply_to" TEXT,
  "mailbox_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("mailbox_id") REFERENCES "mailboxes" ("id") ON DELETE CASCADE
);

CREATE TABLE "epics" (
  "id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "slug" TEXT NOT NULL,
  "description" TEXT,
  "account_id" TEXT,
  "project_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'draft',
  "failure_reason" TEXT,
  "dispatched_at" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "events" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "event_type" TEXT NOT NULL,
  "data" TEXT NOT NULL DEFAULT '{}',
  "inserted_at" TEXT NOT NULL
);

CREATE TABLE "external_users" (
  "id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "external_id" TEXT,
  "email" TEXT NOT NULL,
  "name" TEXT,
  "metadata" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "file_edits" (
  "id" TEXT NOT NULL,
  "external_session_id" TEXT NOT NULL,
  "file_path" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "agent_id" TEXT,
  PRIMARY KEY ("id")
);

CREATE TABLE "files" (
  "id" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "role" TEXT NOT NULL,
  "mtime" TEXT,
  "size" INTEGER,
  "component_id" TEXT,
  "project_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "valid" INTEGER,
  "validation_errors" TEXT,
  "fingerprint" TEXT,
  "story_id" INTEGER,
  "working_copy_id" TEXT NOT NULL,
  "criterion_number" INTEGER,
  "module_name" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("component_id") REFERENCES "components" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE CASCADE
);

CREATE TABLE "fleet_holds" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "reason" TEXT NOT NULL,
  "placed_by" TEXT,
  "status" TEXT NOT NULL DEFAULT 'active',
  "lifted_by" TEXT,
  "lifted_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "graph_invalidations" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "project_id" TEXT NOT NULL,
  "component_id" TEXT,
  "story_id" INTEGER,
  "source" TEXT NOT NULL,
  "observation_id" TEXT,
  "inserted_at" TEXT NOT NULL,
  "entity_scope" TEXT,
  "kind" TEXT,
  "payload" TEXT,
  "working_copy_id" TEXT,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "intake_interview_turns" (
  "id" TEXT NOT NULL,
  "plan_id" TEXT NOT NULL,
  "position" INTEGER NOT NULL,
  "question" TEXT NOT NULL,
  "answer" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("plan_id") REFERENCES "intake_plans" ("id") ON DELETE CASCADE
);

CREATE TABLE "intake_plans" (
  "id" TEXT NOT NULL,
  "session_token" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "description" TEXT,
  "needs_sign_in" INTEGER,
  "separate_copies" INTEGER,
  "who_uses" TEXT,
  "summary" TEXT,
  "first_build" TEXT,
  "account_name" TEXT,
  "project_name" TEXT,
  "account_id" TEXT,
  "project_id" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "location" TEXT,
  "shaping_turns" TEXT NOT NULL DEFAULT '[]',
  "pending_question" TEXT,
  "shaping_status" TEXT NOT NULL DEFAULT 'idle',
  "procedural" INTEGER,
  "technical" INTEGER,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE SET NULL
);

CREATE TABLE "integrations" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "user_id" INTEGER NOT NULL,
  "provider" TEXT NOT NULL,
  "access_token" BLOB NOT NULL,
  "refresh_token" BLOB,
  "expires_at" TEXT NOT NULL,
  "granted_scopes" TEXT DEFAULT '[]',
  "provider_metadata" TEXT DEFAULT '{}',
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE
);

CREATE TABLE "invitations" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "token" TEXT NOT NULL,
  "email" TEXT NOT NULL,
  "role" TEXT NOT NULL,
  "expires_at" TEXT NOT NULL,
  "accepted_at" TEXT,
  "cancelled_at" TEXT,
  "invited_by_id" INTEGER NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  FOREIGN KEY ("invited_by_id") REFERENCES "users" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE
);

CREATE TABLE "issue_qa_attempts" (
  "id" TEXT NOT NULL,
  "issue_id" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "scenarios" TEXT NOT NULL,
  "issue_ids" TEXT NOT NULL,
  "agent_id" TEXT,
  "task_id" TEXT,
  "submitted_at" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("issue_id") REFERENCES "issues" ("id") ON DELETE CASCADE
);

CREATE TABLE "issue_qa_resumes" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "issue_id" TEXT NOT NULL,
  "attempt_id" TEXT NOT NULL,
  "working_copy_id" TEXT NOT NULL,
  "coding_agent_id" TEXT NOT NULL,
  "coding_task_id" TEXT NOT NULL,
  "authorized_by_agent_id" TEXT NOT NULL,
  "candidate_sha" TEXT NOT NULL,
  "reason" TEXT NOT NULL,
  "authorized_at" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id"),
  FOREIGN KEY ("issue_id") REFERENCES "issues" ("id"),
  FOREIGN KEY ("attempt_id") REFERENCES "issue_qa_attempts" ("id"),
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id"),
  FOREIGN KEY ("coding_agent_id") REFERENCES "agents" ("id"),
  FOREIGN KEY ("authorized_by_agent_id") REFERENCES "agents" ("id")
);

CREATE TABLE "issues" (
  "id" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "severity" TEXT NOT NULL,
  "scope" TEXT NOT NULL DEFAULT 'app',
  "description" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'incoming',
  "resolution" TEXT,
  "story_id" INTEGER,
  "source_path" TEXT,
  "project_id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "source" TEXT NOT NULL DEFAULT 'qa_agent',
  "reported_by_id" INTEGER,
  "attachments" TEXT DEFAULT '[]',
  "category" TEXT,
  "synced_from_server" INTEGER,
  "working_copy_id" TEXT,
  "assigned_working_copy_id" TEXT,
  "awaiting_role" TEXT,
  "landed_commit" TEXT,
  "story_submission_ref" TEXT,
  "story_submission_revision" TEXT,
  "story_submission_evidence" TEXT,
  "story_submitted_at" TEXT,
  "story_submission_history" TEXT NOT NULL DEFAULT '[]',
  "qa_ready_commit" TEXT,
  "qa_ready_at" TEXT,
  "fault_key" TEXT,
  "accepted_at" TEXT,
  "closed_at" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("assigned_working_copy_id") REFERENCES "working_copies" ("id") ON DELETE SET NULL
);

CREATE TABLE "linked_servers" (
  "id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "provider" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "environment" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE
);

CREATE TABLE "locks" (
  "key" TEXT NOT NULL,
  PRIMARY KEY ("key")
);

CREATE TABLE "mailboxes" (
  "id" TEXT NOT NULL,
  "address" TEXT NOT NULL,
  "catch_all" INTEGER NOT NULL,
  "project_id" TEXT NOT NULL,
  "user_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE SET NULL
);

CREATE TABLE "members" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "role" TEXT NOT NULL DEFAULT 'member',
  "user_id" INTEGER NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE
);

CREATE TABLE "oauth_access_grants" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "token" TEXT NOT NULL,
  "expires_in" INTEGER NOT NULL,
  "redirect_uri" TEXT NOT NULL,
  "revoked_at" TEXT,
  "scopes" TEXT,
  "resource_owner_id" INTEGER,
  "application_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("resource_owner_id") REFERENCES "users" ("id"),
  FOREIGN KEY ("application_id") REFERENCES "oauth_applications" ("id")
);

CREATE TABLE "oauth_access_tokens" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "token" TEXT NOT NULL,
  "refresh_token" TEXT,
  "expires_in" INTEGER,
  "revoked_at" TEXT,
  "scopes" TEXT,
  "previous_refresh_token" TEXT NOT NULL DEFAULT '',
  "resource_owner_id" INTEGER,
  "application_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "device_id" TEXT,
  FOREIGN KEY ("resource_owner_id") REFERENCES "users" ("id"),
  FOREIGN KEY ("application_id") REFERENCES "oauth_applications" ("id")
);

CREATE TABLE "oauth_applications" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" TEXT NOT NULL,
  "uid" TEXT NOT NULL,
  "secret" TEXT NOT NULL DEFAULT '',
  "redirect_uri" TEXT NOT NULL,
  "scopes" TEXT NOT NULL DEFAULT '',
  "owner_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("owner_id") REFERENCES "users" ("id")
);

CREATE TABLE "oauth_device_grants" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "device_code" TEXT NOT NULL,
  "user_code" TEXT NOT NULL,
  "application_id" INTEGER NOT NULL,
  "device_id" TEXT,
  "resource_owner_id" INTEGER,
  "scopes" TEXT,
  "expires_at" TEXT NOT NULL,
  "interval" INTEGER NOT NULL DEFAULT 5,
  "denied_at" TEXT,
  "access_token_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "consumed_at" TEXT,
  FOREIGN KEY ("application_id") REFERENCES "oauth_applications" ("id"),
  FOREIGN KEY ("resource_owner_id") REFERENCES "users" ("id"),
  FOREIGN KEY ("access_token_id") REFERENCES "oauth_access_tokens" ("id")
);

CREATE TABLE "offer_messages" (
  "id" TEXT NOT NULL,
  "offer_id" TEXT NOT NULL,
  "message_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("offer_id") REFERENCES "offers" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("message_id") REFERENCES "conversation_messages" ("id") ON DELETE CASCADE
);

CREATE TABLE "offers" (
  "id" TEXT NOT NULL,
  "account_id" TEXT,
  "project_id" TEXT,
  "agent_id" TEXT NOT NULL,
  "working_copy_id" TEXT,
  "kind" TEXT NOT NULL,
  "subject_type" TEXT NOT NULL,
  "subject_key" TEXT,
  "attempt" INTEGER NOT NULL,
  "status" TEXT NOT NULL,
  "outcome_at" TEXT,
  "reason" TEXT,
  "note" TEXT,
  "next_step" TEXT,
  "template_version" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "turn_requested_at" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("agent_id") REFERENCES "agents" ("id") ON DELETE CASCADE
);

CREATE TABLE "permission_requests" (
  "id" TEXT NOT NULL,
  "user_id" INTEGER NOT NULL,
  "tool_name" TEXT NOT NULL,
  "tool_input" TEXT NOT NULL DEFAULT '{}',
  "status" TEXT NOT NULL DEFAULT 'pending',
  "decision" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "agent_id" TEXT,
  "task_id" TEXT,
  "escalation_reason" TEXT,
  "escalated_as" TEXT,
  "answered_by_user_id" INTEGER,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("answered_by_user_id") REFERENCES "users" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("agent_id") REFERENCES "agents" ("id") ON DELETE SET NULL
);

CREATE TABLE "persona_stories" (
  "id" TEXT NOT NULL,
  "persona_id" TEXT NOT NULL,
  "story_id" INTEGER NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("persona_id") REFERENCES "personas" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE CASCADE
);

CREATE TABLE "personas" (
  "id" TEXT NOT NULL,
  "slug" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "headline" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "persona_type" TEXT DEFAULT 'proto',
  "project_id" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "problems" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "severity" TEXT NOT NULL,
  "source_type" TEXT NOT NULL,
  "source" TEXT NOT NULL,
  "file_path" TEXT NOT NULL,
  "line" INTEGER,
  "message" TEXT NOT NULL,
  "category" TEXT NOT NULL,
  "rule" TEXT,
  "metadata" TEXT,
  "project_id" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "component_id" TEXT,
  "working_copy_id" TEXT,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("component_id") REFERENCES "components" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE SET NULL
);

CREATE TABLE "project_configurations" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "require_specs" INTEGER,
  "require_reviews" INTEGER,
  "require_unit_tests" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "spec_validation" TEXT,
  "qa_validation" TEXT,
  "subagent_ttl_minutes" INTEGER NOT NULL DEFAULT 10,
  "fix_issues_min_severity" TEXT,
  "devops" TEXT,
  "main_agent_cadence_seconds" INTEGER,
  "architecture" TEXT,
  "advisory_findings" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "project_dependencies" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "version" TEXT,
  "source" TEXT,
  "projected_version" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "checksum" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "project_secrets" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "project_id" TEXT,
  "key" TEXT NOT NULL,
  "value" BLOB NOT NULL,
  "environment" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "account_id" TEXT,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE
);

CREATE TABLE "projects" (
  "name" TEXT,
  "code_repo" TEXT,
  "docs_repo" TEXT,
  "status" TEXT,
  "setup_error" TEXT,
  "user_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "module_name" TEXT,
  "client_api_url" TEXT,
  "google_analytics_property_id" TEXT,
  "id" TEXT NOT NULL,
  "account_id" TEXT,
  "local_path" TEXT,
  "oauth_application_id" INTEGER,
  "client_user_id" INTEGER,
  "deploy_key" BLOB,
  "deploy_key_hash" TEXT,
  "domain" TEXT,
  "domain_verified_at" TEXT,
  "resend_domain_id" TEXT,
  "content_source_path" TEXT,
  "image_bucket" TEXT,
  "images_host" TEXT,
  "content_bucket" TEXT,
  "aws_access_key_id" BLOB,
  "aws_secret_access_key" BLOB,
  "aws_region" TEXT,
  "cms_refresh_secret_hash" TEXT,
  "setup_options" TEXT,
  "s3_endpoint" TEXT,
  "default_working_copy_id" TEXT,
  "health_route_status" TEXT,
  "head_commit" TEXT,
  "preview_extra_frame_origins" TEXT,
  "mix_lock_fingerprint" TEXT,
  "components_authored_at" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id"),
  FOREIGN KEY ("oauth_application_id") REFERENCES "oauth_applications" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("default_working_copy_id") REFERENCES "working_copies" ("id") ON DELETE SET NULL
);

CREATE TABLE "promotion_queue_entries" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "working_copy_id" TEXT NOT NULL,
  "commit" TEXT NOT NULL,
  "requested_by_agent_id" TEXT,
  "restart" INTEGER NOT NULL,
  "status" TEXT NOT NULL,
  "batch_id" TEXT,
  "result" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "subject_type" TEXT,
  "subject_id" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE CASCADE
);

CREATE TABLE "provisioning_environments" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "host" TEXT,
  "server_name" TEXT,
  "ip" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "server_id" TEXT,
  "first_deployed_at" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("server_id") REFERENCES "linked_servers" ("id") ON DELETE SET NULL
);

CREATE TABLE "provisioning_steps" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "project_id" TEXT NOT NULL,
  "key" TEXT NOT NULL,
  "state" TEXT NOT NULL,
  "position" INTEGER NOT NULL,
  "attempted" TEXT,
  "provider_error" TEXT,
  "paused_instructions" TEXT,
  "resources" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "started_at" TEXT,
  "verified_at" TEXT,
  "environment" TEXT,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "push_subscriptions" (
  "id" TEXT NOT NULL,
  "user_id" INTEGER NOT NULL,
  "endpoint" TEXT NOT NULL,
  "p256dh_key" TEXT NOT NULL,
  "auth_key" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE
);

CREATE TABLE "qa_attempts" (
  "id" TEXT NOT NULL,
  "story_id" INTEGER NOT NULL,
  "status" TEXT NOT NULL,
  "scenarios" TEXT NOT NULL,
  "issue_ids" TEXT NOT NULL,
  "agent_id" TEXT,
  "task_id" TEXT,
  "parent_attempt_id" TEXT,
  "submitted_at" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "tools_used" TEXT,
  "evidence" TEXT,
  "review_started_at" TEXT,
  "review_certified_at" TEXT,
  "stale" INTEGER NOT NULL DEFAULT 0,
  "reviewed_commit" TEXT,
  "reviewed_submissions" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("parent_attempt_id") REFERENCES "qa_attempts" ("id") ON DELETE SET NULL
);

CREATE TABLE "qa_invalidations" (
  "id" TEXT NOT NULL,
  "qa_attempt_id" TEXT NOT NULL,
  "invalidated_by_user_id" INTEGER,
  "reason" TEXT NOT NULL,
  "invalidated_at" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "cause" TEXT,
  "actor_id" TEXT,
  "issue_id" TEXT,
  "submission_ref" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("qa_attempt_id") REFERENCES "qa_attempts" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("invalidated_by_user_id") REFERENCES "users" ("id") ON DELETE SET NULL
);

CREATE TABLE "question_requests" (
  "id" TEXT NOT NULL,
  "user_id" INTEGER NOT NULL,
  "title" TEXT,
  "questions" TEXT NOT NULL DEFAULT '[]',
  "status" TEXT NOT NULL DEFAULT 'pending',
  "answers" TEXT NOT NULL DEFAULT '{}',
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "session_external_id" TEXT,
  "agent_id" TEXT,
  "conversation_message_id" TEXT,
  "holder" TEXT,
  "escalation_reason" TEXT,
  "answered_by" TEXT,
  "overruled" INTEGER,
  "task_id" TEXT,
  "answer_history" TEXT,
  "withdrawn_reason" TEXT,
  "story_id" INTEGER,
  "escalated_by" TEXT,
  "answered_by_user_id" INTEGER,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("answered_by_user_id") REFERENCES "users" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("agent_id") REFERENCES "agents" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("conversation_message_id") REFERENCES "conversation_messages" ("id") ON DELETE SET NULL
);

CREATE TABLE "questions" (
  "id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "story_id" INTEGER NOT NULL,
  "text" TEXT NOT NULL,
  "status" TEXT NOT NULL DEFAULT 'open',
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "resolution" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE CASCADE
);

CREATE TABLE "requirement_edges" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "from_requirement_id" INTEGER NOT NULL,
  "to_requirement_id" INTEGER NOT NULL,
  "inserted_at" TEXT NOT NULL,
  FOREIGN KEY ("from_requirement_id") REFERENCES "requirements" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("to_requirement_id") REFERENCES "requirements" ("id") ON DELETE CASCADE
);

CREATE TABLE "requirements" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" TEXT NOT NULL,
  "description" TEXT NOT NULL,
  "checker_module" TEXT,
  "satisfied_by" TEXT,
  "satisfied" INTEGER NOT NULL DEFAULT 0,
  "checked_at" TEXT,
  "details" TEXT NOT NULL DEFAULT '{}',
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "component_id" TEXT,
  "artifact_type" TEXT NOT NULL DEFAULT 'specification',
  "score" REAL,
  "story_id" INTEGER,
  "project_id" TEXT,
  "scope" TEXT DEFAULT 'local',
  "depends_on" TEXT DEFAULT '[]',
  "validation_type" TEXT,
  "execution_type" TEXT,
  "working_copy_id" TEXT,
  "inputs_fingerprint" TEXT,
  "owner_component_type" TEXT,
  "node_scope" TEXT,
  "issue_id" TEXT,
  FOREIGN KEY ("issue_id") REFERENCES "issues" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("component_id") REFERENCES "components" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE CASCADE
);

CREATE TABLE "resource_acknowledgements" (
  "id" TEXT NOT NULL,
  "account_id" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "location" TEXT NOT NULL,
  "note" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE
);

CREATE TABLE "rules" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" TEXT,
  "content" TEXT,
  "component_type" TEXT,
  "session_type" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "account_id" TEXT,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id")
);

CREATE TABLE "screen_states" (
  "id" TEXT NOT NULL,
  "user_id" INTEGER NOT NULL,
  "project_id" TEXT NOT NULL,
  "open_panels" TEXT,
  "dynamic_view" TEXT,
  "dynamic_story_id" INTEGER,
  "offered_view" TEXT,
  "offered_story_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("dynamic_story_id") REFERENCES "stories" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("offered_story_id") REFERENCES "stories" ("id") ON DELETE SET NULL
);

CREATE TABLE "similar_components" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "component_id" TEXT NOT NULL,
  "similar_component_id" TEXT NOT NULL,
  FOREIGN KEY ("component_id") REFERENCES "components" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("similar_component_id") REFERENCES "components" ("id") ON DELETE CASCADE
);

CREATE TABLE "stories" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "title" TEXT,
  "description" TEXT,
  "acceptance_criteria" TEXT,
  "locked_at" TEXT,
  "lock_expires_at" TEXT,
  "locked_by" INTEGER,
  "first_version_id" INTEGER,
  "current_version_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "component_id" TEXT,
  "project_id" TEXT,
  "account_id" TEXT,
  "priority" INTEGER,
  "epic_id" TEXT,
  "ready_for_dev" INTEGER,
  "story" TEXT,
  "notes" TEXT,
  "specs_ready" INTEGER,
  "migrated_from_id" INTEGER,
  "number" INTEGER,
  "three_amigos_sealed" INTEGER NOT NULL DEFAULT 0,
  "working_copy_id" TEXT,
  "promoted_version" TEXT,
  "specs_ready_at" TEXT,
  "specs_ready_commit" TEXT,
  "retired_at" TEXT,
  "qa_ready_commit" TEXT,
  "qa_ready_at" TEXT,
  "promoted_working_copy_id" TEXT,
  "promoted_at" TEXT,
  "qa_reviewed_commit" TEXT,
  "qa_reviewed_at" TEXT,
  FOREIGN KEY ("locked_by") REFERENCES "users" ("id"),
  FOREIGN KEY ("first_version_id") REFERENCES "versions" ("id"),
  FOREIGN KEY ("current_version_id") REFERENCES "versions" ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("epic_id") REFERENCES "epics" ("id") ON DELETE SET NULL,
  FOREIGN KEY ("working_copy_id") REFERENCES "working_copies" ("id") ON DELETE SET NULL
);

CREATE TABLE "story_tags" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "tag_id" INTEGER NOT NULL,
  "story_id" INTEGER NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  FOREIGN KEY ("story_id") REFERENCES "stories" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("tag_id") REFERENCES "component_tags" ("id") ON DELETE CASCADE
);

CREATE TABLE "stripe_events" (
  "id" TEXT NOT NULL,
  "event_id" TEXT NOT NULL,
  "type" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  PRIMARY KEY ("id")
);

CREATE TABLE "tags" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" TEXT NOT NULL,
  "slug" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL
);

CREATE TABLE "telemetry_health_checks" (
  "project_id" TEXT NOT NULL,
  "environment" TEXT NOT NULL,
  "reachable" INTEGER NOT NULL,
  "reads" TEXT NOT NULL,
  "writes" TEXT NOT NULL,
  "checked_at" TEXT NOT NULL,
  PRIMARY KEY ("project_id", "environment"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE TABLE "user_preferences" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "token" TEXT,
  "user_id" INTEGER,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "active_project_id" TEXT,
  "active_account_id" TEXT,
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE
);

CREATE TABLE "users" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "email" BLOB NOT NULL,
  "hashed_password" TEXT,
  "confirmed_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "cli_first_connected_at" TEXT
);

CREATE TABLE "users_tokens" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "user_id" INTEGER NOT NULL,
  "token" BLOB NOT NULL,
  "context" TEXT NOT NULL,
  "sent_to" TEXT,
  "authenticated_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE
);

CREATE TABLE "validation_holds" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "owner_agent_id" TEXT NOT NULL,
  "reason" TEXT NOT NULL,
  "affected_copy_ids" TEXT NOT NULL,
  "authorized_copy_id" TEXT,
  "source" TEXT,
  "args" TEXT NOT NULL DEFAULT '[]',
  "next_agent_id" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "run_id" INTEGER,
  "outcome" TEXT,
  "history" TEXT NOT NULL DEFAULT '{"events": []}',
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("run_id") REFERENCES "analysis_runs" ("id") ON DELETE SET NULL
);

CREATE TABLE "versions" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "event" TEXT NOT NULL,
  "item_type" TEXT NOT NULL,
  "item_id" INTEGER,
  "item_changes" TEXT NOT NULL,
  "originator_id" INTEGER,
  "origin" TEXT,
  "meta" TEXT,
  "inserted_at" TEXT NOT NULL,
  FOREIGN KEY ("originator_id") REFERENCES "users" ("id")
);

CREATE TABLE "working_copies" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "label" TEXT,
  "last_seen_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "root" TEXT,
  "device_id" TEXT,
  "path_missing_since" TEXT,
  "main" INTEGER NOT NULL DEFAULT 0,
  "preview_url" TEXT,
  "preview_tunnel_id" TEXT,
  "preview_tunnel_secret" BLOB,
  "machine_tools" TEXT,
  "browser_status" TEXT,
  "browser_error" TEXT,
  "machine_tool_docs" TEXT,
  "preview_status" TEXT,
  "preview_checked_at" TEXT,
  "app_status" TEXT,
  "app_checked_at" TEXT,
  "app_url" TEXT,
  "app_commit" TEXT,
  "app_serving_commit" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("device_id") REFERENCES "devices" ("id") ON DELETE CASCADE
);

CREATE TABLE "workspaces" (
  "id" TEXT NOT NULL,
  "project_id" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "container_name" TEXT,
  "port" INTEGER,
  "error" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "step" TEXT,
  "booted_at" TEXT,
  PRIMARY KEY ("id"),
  FOREIGN KEY ("project_id") REFERENCES "projects" ("id") ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS accounts_slug_index ON accounts (slug);

CREATE UNIQUE INDEX IF NOT EXISTS accounts_stripe_customer_id_index ON accounts (stripe_customer_id);

CREATE INDEX IF NOT EXISTS activity_entries_project_id_inserted_at_index ON activity_entries (project_id, inserted_at);

CREATE INDEX IF NOT EXISTS activity_entries_project_id_resource_inserted_at_index ON activity_entries (project_id, resource, inserted_at);

CREATE INDEX IF NOT EXISTS agent_mailbox_agent_id_id_index ON agent_mailbox (agent_id, id);

CREATE UNIQUE INDEX IF NOT EXISTS agent_mailbox_delivery_ref_index ON agent_mailbox (delivery_ref);

CREATE UNIQUE INDEX IF NOT EXISTS agent_mailbox_message_id_index ON agent_mailbox (message_id);

CREATE UNIQUE INDEX IF NOT EXISTS agent_mailbox_one_owner ON agent_mailbox (agent_id) WHERE (state IN ('claimed', 'consumed', 'uncertain'));

CREATE UNIQUE INDEX IF NOT EXISTS agent_model_settings_user_id_role_index ON agent_model_settings (user_id, role);

CREATE INDEX IF NOT EXISTS agent_restarts_agent_id_resolved_at_index ON agent_restarts (agent_id, resolved_at);

CREATE INDEX IF NOT EXISTS agent_turns_agent_id_index ON agent_turns (agent_id);

CREATE INDEX IF NOT EXISTS agent_turns_project_id_index ON agent_turns (project_id);

CREATE INDEX IF NOT EXISTS agent_turns_story_id_index ON agent_turns (story_id);

CREATE INDEX IF NOT EXISTS agents_account_id_index ON agents (account_id);

CREATE INDEX IF NOT EXISTS agents_epic_id_index ON agents (epic_id);

CREATE INDEX IF NOT EXISTS agents_harness_id_role_index ON agents (working_copy_id, role);

CREATE INDEX IF NOT EXISTS agents_issue_id_index ON agents (issue_id);

CREATE UNIQUE INDEX IF NOT EXISTS agents_project_id_engine_session_id_index ON agents (project_id, engine_session_id) WHERE (engine_session_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS agents_project_id_index ON agents (project_id);

CREATE INDEX IF NOT EXISTS agents_project_id_status_index ON agents (project_id, status);

CREATE INDEX IF NOT EXISTS agents_project_id_working_copy_role_index ON agents (project_id, working_copy, role);

CREATE INDEX IF NOT EXISTS agents_story_id_index ON agents (story_id);

CREATE INDEX IF NOT EXISTS agents_working_copy_id_continuous_index ON agents (working_copy_id, continuous);

CREATE INDEX IF NOT EXISTS agents_working_copy_index ON agents (working_copy);

CREATE INDEX IF NOT EXISTS analysis_run_waiters_agent_id_index ON analysis_run_waiters (agent_id);

CREATE UNIQUE INDEX IF NOT EXISTS analysis_run_waiters_run_id_agent_id_index ON analysis_run_waiters (run_id, agent_id);

CREATE INDEX IF NOT EXISTS analysis_runs_project_id_harness_id_status_index ON analysis_runs (project_id, working_copy_id, status);

CREATE INDEX IF NOT EXISTS analysis_runs_project_id_source_status_index ON analysis_runs (project_id, source, status);

CREATE INDEX IF NOT EXISTS analysis_runs_requester_agent_id_index ON analysis_runs (requester_agent_id);

CREATE INDEX IF NOT EXISTS app_restarts_working_copy_id_index ON app_restarts (working_copy_id);

CREATE INDEX IF NOT EXISTS bdd_rules_account_id_index ON bdd_rules (account_id);

CREATE INDEX IF NOT EXISTS bdd_rules_project_id_index ON bdd_rules (project_id);

CREATE INDEX IF NOT EXISTS bdd_rules_story_id_index ON bdd_rules (story_id);

CREATE UNIQUE INDEX IF NOT EXISTS capability_gaps_project_id_role_capability_index ON capability_gaps (project_id, role, capability);

CREATE UNIQUE INDEX IF NOT EXISTS client_users_email_index ON client_users (email);

CREATE UNIQUE INDEX IF NOT EXISTS completion_handoffs_project_id_identity_index ON completion_handoffs (project_id, identity);

CREATE INDEX IF NOT EXISTS completion_handoffs_project_id_status_index ON completion_handoffs (project_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS component_tags_name_project_id_index ON component_tags (name, project_id);

CREATE INDEX IF NOT EXISTS component_tags_project_id_index ON component_tags (project_id);

CREATE INDEX IF NOT EXISTS components_account_id_index ON components (account_id);

CREATE INDEX IF NOT EXISTS components_files_changed_at_index ON components (files_changed_at);

CREATE UNIQUE INDEX IF NOT EXISTS components_module_name_project_id_index ON components (module_name, project_id);

CREATE INDEX IF NOT EXISTS components_parent_component_id_index ON components (parent_component_id);

CREATE INDEX IF NOT EXISTS components_type_index ON components (type);

CREATE INDEX IF NOT EXISTS content_admin_account_id_index ON content_admin (account_id);

CREATE INDEX IF NOT EXISTS content_admin_parse_status_index ON content_admin (parse_status);

CREATE UNIQUE INDEX IF NOT EXISTS content_images_project_id_key_index ON content_images (project_id, key);

CREATE INDEX IF NOT EXISTS content_snapshots_project_id_index ON content_snapshots (project_id);

CREATE INDEX IF NOT EXISTS content_tags_content_id_index ON content_tags (content_id);

CREATE UNIQUE INDEX IF NOT EXISTS content_tags_content_id_tag_id_index ON content_tags (content_id, tag_id);

CREATE INDEX IF NOT EXISTS content_tags_tag_id_index ON content_tags (tag_id);

CREATE INDEX IF NOT EXISTS contents_content_type_index ON contents (content_type);

CREATE INDEX IF NOT EXISTS contents_expires_at_index ON contents (expires_at);

CREATE INDEX IF NOT EXISTS contents_protected_index ON contents (protected);

CREATE INDEX IF NOT EXISTS contents_publish_at_expires_at_index ON contents (publish_at, expires_at);

CREATE INDEX IF NOT EXISTS contents_publish_at_index ON contents (publish_at);

CREATE UNIQUE INDEX IF NOT EXISTS contents_slug_content_type_index ON contents (slug, content_type);

CREATE INDEX IF NOT EXISTS conversation_checkpoints_conversation_id_index ON conversation_checkpoints (conversation_id);

CREATE INDEX IF NOT EXISTS conversation_messages_conversation_id_index ON conversation_messages (conversation_id);

CREATE INDEX IF NOT EXISTS conversation_messages_delivery_ref_index ON conversation_messages (delivery_ref);

CREATE INDEX IF NOT EXISTS conversation_reads_conversation_id_index ON conversation_reads (conversation_id);

CREATE UNIQUE INDEX IF NOT EXISTS conversation_reads_user_id_conversation_id_index ON conversation_reads (user_id, conversation_id);

CREATE INDEX IF NOT EXISTS conversations_account_id_index ON conversations (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS conversations_account_id_project_id_end_user_email_index ON conversations (account_id, project_id, end_user_email);

CREATE INDEX IF NOT EXISTS conversations_account_id_read_index ON conversations (account_id, read);

CREATE INDEX IF NOT EXISTS conversations_account_id_type_index ON conversations (account_id, type);

CREATE UNIQUE INDEX IF NOT EXISTS conversations_account_project_session_index ON conversations (account_id, project_id, session_external_id) WHERE (session_external_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS conversations_agent_id_index ON conversations (agent_id);

CREATE UNIQUE INDEX IF NOT EXISTS conversations_agent_index ON conversations (agent_id) WHERE (agent_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS criteria_project_id_index ON criteria (project_id);

CREATE UNIQUE INDEX IF NOT EXISTS criteria_project_id_number_index ON criteria (project_id, number);

CREATE INDEX IF NOT EXISTS criteria_rule_id_index ON criteria (rule_id);

CREATE INDEX IF NOT EXISTS criteria_story_id_index ON criteria (story_id);

CREATE INDEX IF NOT EXISTS dependencies_source_component_id_index ON dependencies (source_component_id);

CREATE UNIQUE INDEX IF NOT EXISTS dependencies_source_component_id_target_component_id_index ON dependencies (source_component_id, target_component_id);

CREATE INDEX IF NOT EXISTS dependencies_target_component_id_index ON dependencies (target_component_id);

CREATE INDEX IF NOT EXISTS deploys_project_id_environment_index ON deploys (project_id, environment);

CREATE UNIQUE INDEX IF NOT EXISTS deploys_story_id_environment_index ON deploys (story_id, environment);

CREATE INDEX IF NOT EXISTS devices_account_id_index ON devices (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS devices_token_hash_index ON devices (token_hash) WHERE (token_hash IS NOT NULL);

CREATE INDEX IF NOT EXISTS doc_embeddings_content_hash_lookup_index ON doc_embeddings (project_id, source, path, content_hash);

CREATE INDEX IF NOT EXISTS doc_embeddings_package_version_index ON doc_embeddings (package, version);

CREATE UNIQUE INDEX IF NOT EXISTS doc_embeddings_path_chunk_index ON doc_embeddings (project_id, source, path, chunk_index) WHERE (project_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS doc_embeddings_project_id_index ON doc_embeddings (project_id);

CREATE UNIQUE INDEX IF NOT EXISTS doc_embeddings_shared_identity_index ON doc_embeddings (package, version, model, path, chunk_index) WHERE (project_id IS NULL);

CREATE INDEX IF NOT EXISTS doc_embeddings_source_path_index ON doc_embeddings (source, path);

CREATE UNIQUE INDEX IF NOT EXISTS doc_packages_package_version_model_index ON doc_packages (package, version, model);

CREATE INDEX IF NOT EXISTS email_attachments_email_id_index ON email_attachments (email_id);

CREATE UNIQUE INDEX IF NOT EXISTS email_attachments_email_id_provider_attachment_id_index ON email_attachments (email_id, provider_attachment_id);

CREATE INDEX IF NOT EXISTS emails_mailbox_id_correspondent_index ON emails (mailbox_id, correspondent);

CREATE INDEX IF NOT EXISTS emails_mailbox_id_index ON emails (mailbox_id);

CREATE UNIQUE INDEX IF NOT EXISTS emails_message_id_index ON emails (message_id) WHERE (message_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS epics_account_id_index ON epics (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS epics_project_id_name_index ON epics (project_id, name);

CREATE UNIQUE INDEX IF NOT EXISTS epics_project_id_slug_index ON epics (project_id, slug);

CREATE INDEX IF NOT EXISTS epics_project_id_status_index ON epics (project_id, status);

CREATE INDEX IF NOT EXISTS events_event_type_index ON events (event_type);

CREATE INDEX IF NOT EXISTS events_event_type_inserted_at_index ON events (event_type, inserted_at);

CREATE INDEX IF NOT EXISTS external_users_account_id_index ON external_users (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS external_users_project_id_email_index ON external_users (project_id, email);

CREATE INDEX IF NOT EXISTS file_edits_agent_id_index ON file_edits (agent_id) WHERE (agent_id IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS file_edits_external_session_id_file_path_index ON file_edits (external_session_id, file_path);

CREATE INDEX IF NOT EXISTS file_edits_external_session_id_index ON file_edits (external_session_id);

CREATE INDEX IF NOT EXISTS files_component_id_index ON files (component_id);

CREATE INDEX IF NOT EXISTS files_harness_id_index ON files (working_copy_id);

CREATE INDEX IF NOT EXISTS files_project_id_criterion_number_index ON files (project_id, criterion_number);

CREATE INDEX IF NOT EXISTS files_project_id_harness_id_index ON files (project_id, working_copy_id);

CREATE UNIQUE INDEX IF NOT EXISTS files_project_id_harness_id_path_index ON files (project_id, working_copy_id, path);

CREATE INDEX IF NOT EXISTS files_project_id_module_name_index ON files (project_id, module_name);

CREATE INDEX IF NOT EXISTS files_role_index ON files (role);

CREATE INDEX IF NOT EXISTS files_story_id_index ON files (story_id);

CREATE INDEX IF NOT EXISTS files_valid_index ON files (valid);

CREATE UNIQUE INDEX IF NOT EXISTS fleet_holds_one_active_per_project ON fleet_holds (project_id) WHERE ((status)= 'active');

CREATE INDEX IF NOT EXISTS graph_invalidations_project_id_index ON graph_invalidations (project_id);

CREATE INDEX IF NOT EXISTS graph_invalidations_project_id_working_copy_id_index ON graph_invalidations (project_id, working_copy_id);

CREATE UNIQUE INDEX IF NOT EXISTS intake_interview_turns_plan_id_position_index ON intake_interview_turns (plan_id, "position");

CREATE UNIQUE INDEX IF NOT EXISTS intake_plans_session_token_index ON intake_plans (session_token);

CREATE INDEX IF NOT EXISTS integrations_expires_at_index ON integrations (expires_at);

CREATE INDEX IF NOT EXISTS integrations_user_id_index ON integrations (user_id);

CREATE UNIQUE INDEX IF NOT EXISTS integrations_user_id_provider_index ON integrations (user_id, provider);

CREATE INDEX IF NOT EXISTS invitations_account_id_index ON invitations (account_id);

CREATE INDEX IF NOT EXISTS invitations_email_index ON invitations (email);

CREATE INDEX IF NOT EXISTS invitations_expires_at_index ON invitations (expires_at);

CREATE UNIQUE INDEX IF NOT EXISTS invitations_token_index ON invitations (token);

CREATE UNIQUE INDEX IF NOT EXISTS unique_account_email_when_nulls ON invitations (email, account_id) WHERE ((accepted_at IS NULL) AND (cancelled_at IS NULL));

CREATE INDEX IF NOT EXISTS issue_qa_attempts_issue_id_index ON issue_qa_attempts (issue_id);

CREATE UNIQUE INDEX IF NOT EXISTS issue_qa_resumes_attempt_id_index ON issue_qa_resumes (attempt_id);

CREATE INDEX IF NOT EXISTS issue_qa_resumes_project_id_issue_id_index ON issue_qa_resumes (project_id, issue_id);

CREATE INDEX IF NOT EXISTS issues_account_id_index ON issues (account_id);

CREATE INDEX IF NOT EXISTS issues_assigned_working_copy_id_index ON issues (assigned_working_copy_id);

CREATE UNIQUE INDEX IF NOT EXISTS issues_fault_key_project_id_index ON issues (fault_key, project_id) WHERE ((fault_key IS NOT NULL) AND ((status)<> 'resolved'));

CREATE INDEX IF NOT EXISTS issues_project_id_harness_id_index ON issues (project_id, working_copy_id);

CREATE INDEX IF NOT EXISTS issues_project_id_index ON issues (project_id);

CREATE INDEX IF NOT EXISTS issues_reported_by_id_index ON issues (reported_by_id);

CREATE INDEX IF NOT EXISTS issues_source_index ON issues (source);

CREATE INDEX IF NOT EXISTS issues_status_index ON issues (status);

CREATE INDEX IF NOT EXISTS issues_story_id_index ON issues (story_id);

CREATE INDEX IF NOT EXISTS issues_synced_from_server_index ON issues (synced_from_server);

CREATE UNIQUE INDEX IF NOT EXISTS issues_title_story_id_project_id_index ON issues (title, story_id, project_id);

CREATE INDEX IF NOT EXISTS linked_servers_account_id_environment_index ON linked_servers (account_id, environment);

CREATE INDEX IF NOT EXISTS linked_servers_account_id_index ON linked_servers (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS linked_servers_account_id_provider_name_index ON linked_servers (account_id, provider, name);

CREATE UNIQUE INDEX IF NOT EXISTS mailboxes_project_id_address_index ON mailboxes (project_id, address);

CREATE INDEX IF NOT EXISTS mailboxes_user_id_index ON mailboxes (user_id);

CREATE INDEX IF NOT EXISTS members_account_id_index ON members (account_id);

CREATE INDEX IF NOT EXISTS members_role_index ON members (role);

CREATE UNIQUE INDEX IF NOT EXISTS members_user_id_account_id_index ON members (user_id, account_id);

CREATE INDEX IF NOT EXISTS members_user_id_index ON members (user_id);

CREATE UNIQUE INDEX IF NOT EXISTS oauth_access_grants_token_index ON oauth_access_grants (token);

CREATE INDEX IF NOT EXISTS oauth_access_tokens_device_id_index ON oauth_access_tokens (device_id) WHERE (device_id IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS oauth_access_tokens_refresh_token_index ON oauth_access_tokens (refresh_token);

CREATE UNIQUE INDEX IF NOT EXISTS oauth_access_tokens_token_index ON oauth_access_tokens (token);

CREATE UNIQUE INDEX IF NOT EXISTS oauth_applications_uid_index ON oauth_applications (uid);

CREATE UNIQUE INDEX IF NOT EXISTS oauth_device_grants_device_code_index ON oauth_device_grants (device_code);

CREATE INDEX IF NOT EXISTS oauth_device_grants_device_id_index ON oauth_device_grants (device_id);

CREATE UNIQUE INDEX IF NOT EXISTS oauth_device_grants_user_code_index ON oauth_device_grants (user_code);

CREATE INDEX IF NOT EXISTS offer_messages_message_id_index ON offer_messages (message_id);

CREATE UNIQUE INDEX IF NOT EXISTS offer_messages_offer_id_message_id_index ON offer_messages (offer_id, message_id);

CREATE INDEX IF NOT EXISTS offers_agent_id_kind_subject_type_subject_key_index ON offers (agent_id, kind, subject_type, subject_key);

CREATE INDEX IF NOT EXISTS offers_agent_id_status_index ON offers (agent_id, status);

CREATE INDEX IF NOT EXISTS offers_agent_id_status_turn_requested_at_index ON offers (agent_id, status, turn_requested_at);

CREATE INDEX IF NOT EXISTS offers_project_id_kind_status_index ON offers (project_id, kind, status);

CREATE INDEX IF NOT EXISTS permission_requests_agent_id_status_index ON permission_requests (agent_id, status);

CREATE INDEX IF NOT EXISTS permission_requests_status_index ON permission_requests (status);

CREATE INDEX IF NOT EXISTS permission_requests_user_id_index ON permission_requests (user_id);

CREATE UNIQUE INDEX IF NOT EXISTS persona_stories_persona_id_story_id_index ON persona_stories (persona_id, story_id);

CREATE INDEX IF NOT EXISTS persona_stories_story_id_index ON persona_stories (story_id);

CREATE INDEX IF NOT EXISTS personas_project_id_index ON personas (project_id);

CREATE UNIQUE INDEX IF NOT EXISTS personas_project_id_slug_index ON personas (project_id, slug);

CREATE INDEX IF NOT EXISTS problems_component_id_index ON problems (component_id);

CREATE INDEX IF NOT EXISTS problems_component_id_source_index ON problems (component_id, source);

CREATE INDEX IF NOT EXISTS problems_file_path_index ON problems (file_path);

CREATE INDEX IF NOT EXISTS problems_harness_id_index ON problems (working_copy_id);

CREATE INDEX IF NOT EXISTS problems_project_id_harness_id_index ON problems (project_id, working_copy_id);

CREATE INDEX IF NOT EXISTS problems_project_id_index ON problems (project_id);

CREATE INDEX IF NOT EXISTS problems_severity_index ON problems (severity);

CREATE INDEX IF NOT EXISTS problems_source_type_index ON problems (source_type);

CREATE UNIQUE INDEX IF NOT EXISTS project_configurations_project_id_index ON project_configurations (project_id);

CREATE UNIQUE INDEX IF NOT EXISTS project_dependencies_project_id_name_index ON project_dependencies (project_id, name);

CREATE INDEX IF NOT EXISTS project_dependencies_project_id_projected_version_index ON project_dependencies (project_id, projected_version);

CREATE INDEX IF NOT EXISTS project_secrets_account_id_index ON project_secrets (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS project_secrets_account_id_key_environment_index ON project_secrets (account_id, key, environment) WHERE (account_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS project_secrets_project_id_index ON project_secrets (project_id);

CREATE UNIQUE INDEX IF NOT EXISTS project_secrets_project_id_key_environment_index ON project_secrets (project_id, key, environment);

CREATE INDEX IF NOT EXISTS projects_account_id_index ON projects (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS projects_cms_refresh_secret_hash_index ON projects (cms_refresh_secret_hash);

CREATE INDEX IF NOT EXISTS projects_default_working_copy_id_index ON projects (default_working_copy_id);

CREATE UNIQUE INDEX IF NOT EXISTS projects_deploy_key_hash_index ON projects (deploy_key_hash);

CREATE INDEX IF NOT EXISTS projects_oauth_application_id_index ON projects (oauth_application_id);

CREATE INDEX IF NOT EXISTS projects_user_id_index ON projects (user_id);

CREATE INDEX IF NOT EXISTS promotion_queue_entries_project_id_status_inserted_at_index ON promotion_queue_entries (project_id, status, inserted_at);

CREATE UNIQUE INDEX IF NOT EXISTS provisioning_environments_project_id_name_index ON provisioning_environments (project_id, name);

CREATE INDEX IF NOT EXISTS provisioning_environments_server_id_index ON provisioning_environments (server_id);

CREATE UNIQUE INDEX IF NOT EXISTS provisioning_steps_project_id_key_environment_index ON provisioning_steps (project_id, key, environment) WHERE (environment IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS provisioning_steps_project_id_key_no_environment_index ON provisioning_steps (project_id, key) WHERE (environment IS NULL);

CREATE INDEX IF NOT EXISTS provisioning_steps_project_id_position_index ON provisioning_steps (project_id, "position");

CREATE UNIQUE INDEX IF NOT EXISTS push_subscriptions_endpoint_index ON push_subscriptions (endpoint);

CREATE INDEX IF NOT EXISTS push_subscriptions_user_id_index ON push_subscriptions (user_id);

CREATE INDEX IF NOT EXISTS qa_attempts_parent_attempt_id_index ON qa_attempts (parent_attempt_id);

CREATE INDEX IF NOT EXISTS qa_attempts_story_id_index ON qa_attempts (story_id);

CREATE INDEX IF NOT EXISTS qa_invalidations_qa_attempt_id_index ON qa_invalidations (qa_attempt_id);

CREATE UNIQUE INDEX IF NOT EXISTS qa_invalidations_unique_attempt_index ON qa_invalidations (qa_attempt_id);

CREATE INDEX IF NOT EXISTS question_requests_agent_id_status_index ON question_requests (agent_id, status);

CREATE INDEX IF NOT EXISTS question_requests_conversation_message_id_index ON question_requests (conversation_message_id);

CREATE INDEX IF NOT EXISTS question_requests_holder_status_index ON question_requests (holder, status);

CREATE INDEX IF NOT EXISTS question_requests_session_external_id_index ON question_requests (session_external_id);

CREATE INDEX IF NOT EXISTS question_requests_status_index ON question_requests (status);

CREATE INDEX IF NOT EXISTS question_requests_user_id_index ON question_requests (user_id);

CREATE INDEX IF NOT EXISTS question_requests_user_id_story_id_status_index ON question_requests (user_id, story_id, status);

CREATE INDEX IF NOT EXISTS questions_account_id_index ON questions (account_id);

CREATE INDEX IF NOT EXISTS questions_project_id_index ON questions (project_id);

CREATE INDEX IF NOT EXISTS questions_story_id_index ON questions (story_id);

CREATE INDEX IF NOT EXISTS questions_story_id_status_index ON questions (story_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS requirement_edges_from_requirement_id_to_requirement_id_index ON requirement_edges (from_requirement_id, to_requirement_id);

CREATE INDEX IF NOT EXISTS requirement_edges_to_requirement_id_index ON requirement_edges (to_requirement_id);

CREATE INDEX IF NOT EXISTS requirements_artifact_type_index ON requirements (artifact_type);

CREATE INDEX IF NOT EXISTS requirements_component_id_index ON requirements (component_id);

CREATE UNIQUE INDEX IF NOT EXISTS requirements_component_id_name_index ON requirements (coalesce(component_id, ''), coalesce(name, ''), coalesce(working_copy_id, '')) WHERE (component_id IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS requirements_issue_id_name_working_copy_id_index ON requirements (coalesce(issue_id, ''), coalesce(name, ''), coalesce(working_copy_id, '')) WHERE (issue_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS requirements_name_index ON requirements (name);

CREATE INDEX IF NOT EXISTS requirements_project_id_index ON requirements (project_id);

CREATE UNIQUE INDEX IF NOT EXISTS requirements_project_id_name_index ON requirements (coalesce(project_id, ''), coalesce(name, ''), coalesce(working_copy_id, '')) WHERE (project_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS requirements_satisfied_index ON requirements (satisfied);

CREATE INDEX IF NOT EXISTS requirements_story_id_index ON requirements (story_id);

CREATE UNIQUE INDEX IF NOT EXISTS requirements_story_id_name_index ON requirements (coalesce(story_id, ''), coalesce(name, ''), coalesce(working_copy_id, '')) WHERE (story_id IS NOT NULL);

CREATE INDEX IF NOT EXISTS requirements_working_copy_id_index ON requirements (working_copy_id);

CREATE INDEX IF NOT EXISTS requirements_working_copy_id_inputs_fingerprint_index ON requirements (working_copy_id, inputs_fingerprint);

CREATE INDEX IF NOT EXISTS resource_acknowledgements_account_id_index ON resource_acknowledgements (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS resource_acknowledgements_account_id_kind_location_index ON resource_acknowledgements (account_id, kind, location);

CREATE INDEX IF NOT EXISTS rules_account_id_index ON rules (account_id);

CREATE UNIQUE INDEX IF NOT EXISTS screen_states_user_id_project_id_index ON screen_states (user_id, project_id);

CREATE INDEX IF NOT EXISTS similar_components_component_id_index ON similar_components (component_id);

CREATE UNIQUE INDEX IF NOT EXISTS similar_components_component_id_similar_component_id_index ON similar_components (component_id, similar_component_id);

CREATE INDEX IF NOT EXISTS similar_components_similar_component_id_index ON similar_components (similar_component_id);

CREATE INDEX IF NOT EXISTS stories_account_id_index ON stories (account_id);

CREATE INDEX IF NOT EXISTS stories_component_id_index ON stories (component_id);

CREATE UNIQUE INDEX IF NOT EXISTS stories_current_version_id_index ON stories (current_version_id);

CREATE INDEX IF NOT EXISTS stories_epic_id_index ON stories (epic_id);

CREATE UNIQUE INDEX IF NOT EXISTS stories_first_version_id_index ON stories (first_version_id);

CREATE INDEX IF NOT EXISTS stories_locked_by_index ON stories (locked_by);

CREATE UNIQUE INDEX IF NOT EXISTS stories_project_id_migrated_from_id_index ON stories (project_id, migrated_from_id) WHERE (migrated_from_id IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS stories_project_id_number_index ON stories (project_id, number);

CREATE INDEX IF NOT EXISTS stories_project_id_working_copy_id_index ON stories (project_id, working_copy_id);

CREATE UNIQUE INDEX IF NOT EXISTS stories_title_project_id_index ON stories (title, project_id);

CREATE INDEX IF NOT EXISTS story_tags_story_id_index ON story_tags (story_id);

CREATE INDEX IF NOT EXISTS story_tags_tag_id_index ON story_tags (tag_id);

CREATE UNIQUE INDEX IF NOT EXISTS story_tags_tag_id_story_id_index ON story_tags (tag_id, story_id);

CREATE UNIQUE INDEX IF NOT EXISTS stripe_events_event_id_index ON stripe_events (event_id);

CREATE UNIQUE INDEX IF NOT EXISTS tags_slug_index ON tags (slug);

CREATE UNIQUE INDEX IF NOT EXISTS user_preferences_user_id_index ON user_preferences (user_id);

CREATE UNIQUE INDEX IF NOT EXISTS users_email_index ON users (email);

CREATE UNIQUE INDEX IF NOT EXISTS users_tokens_context_token_index ON users_tokens (context, token);

CREATE INDEX IF NOT EXISTS users_tokens_user_id_index ON users_tokens (user_id);

CREATE UNIQUE INDEX IF NOT EXISTS validation_holds_one_open_per_project ON validation_holds (project_id) WHERE ((status)<> 'released');

CREATE INDEX IF NOT EXISTS validation_holds_run_id_index ON validation_holds (run_id);

CREATE INDEX IF NOT EXISTS versions_item_id_item_type_index ON versions (item_id, item_type);

CREATE INDEX IF NOT EXISTS versions_originator_id_index ON versions (originator_id);

CREATE INDEX IF NOT EXISTS harnesses_project_id_index ON working_copies (project_id);

CREATE INDEX IF NOT EXISTS harnesses_project_id_last_seen_at_index ON working_copies (project_id, last_seen_at);

CREATE INDEX IF NOT EXISTS working_copies_device_id_index ON working_copies (device_id);

CREATE UNIQUE INDEX IF NOT EXISTS working_copies_one_main_per_project_index ON working_copies (project_id) WHERE main;

CREATE UNIQUE INDEX IF NOT EXISTS workspaces_project_id_index ON workspaces (project_id);
