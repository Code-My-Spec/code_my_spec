defmodule CodeMySpec.Repo.Migrations.TheCliDatabaseCarriesWhatMigrationReads do
  @moduledoc """
  `cms migrate` reads the local CLI database through today's schemas, and the
  CLI migrations stopped following them in October: on a legacy `cli.db` the
  first read (`projects.onboarding`) raised and the move never started.

  Adds every column today's schemas read that this database lacks (found by
  scanning every schema against a legacy `cli.db`), and only those: a column
  already present is left alone, because CLI databases in the wild are at
  different points. Nullable and without defaults, so a migrated row reads
  exactly as a never-set field does.
  """

  use Ecto.Migration

  @columns %{
    "projects" => [
      {"onboarding", "TEXT"},
      {"sources", "TEXT"},
      {"mix_lock_fingerprint", "TEXT"},
      {"development_branch", "TEXT"},
      {"promotion_sync", "TEXT"},
      {"publication_sequence", "INTEGER"},
      {"preview_extra_frame_origins", "TEXT"},
      {"components_authored_at", "TEXT"}
    ],
    "stories" => [
      {"specs_ready_at", "TEXT"},
      {"specs_ready_commit", "TEXT"},
      {"qa_ready_commit", "TEXT"},
      {"qa_ready_at", "TEXT"},
      {"qa_reviewed_commit", "TEXT"},
      {"qa_reviewed_at", "TEXT"},
      {"promoted_version", "TEXT"},
      {"promoted_qa_commit", "TEXT"},
      {"promoted_candidate_commit", "TEXT"},
      {"promoted_working_copy_id", "TEXT"},
      {"promoted_at", "TEXT"},
      {"working_copy_id", "TEXT"}
    ],
    "issues" => [
      {"fault_key", "TEXT"},
      {"assigned_working_copy_id", "TEXT"},
      {"awaiting_role", "TEXT"},
      {"qa_ready_commit", "TEXT"},
      {"qa_ready_at", "TEXT"},
      {"story_submission_ref", "TEXT"},
      {"story_submission_revision", "TEXT"},
      {"story_submission_evidence", "TEXT"},
      {"story_submitted_at", "TEXT"},
      {"story_submission_history", "TEXT"},
      {"landed_commit", "TEXT"},
      {"accepted_at", "TEXT"},
      {"closed_at", "TEXT"}
    ],
    "questions" => [{"resolution", "TEXT"}],
    "qa_attempts" => [
      {"reviewed_commit", "TEXT"},
      {"reviewed_submissions", "TEXT"},
      {"review_started_at", "TEXT"},
      {"review_certified_at", "TEXT"},
      {"stale", "INTEGER"},
      {"tools_used", "TEXT"},
      {"evidence_corrections", "TEXT"},
      {"evidence", "TEXT"}
    ],
    "components" => [{"provenance", "TEXT"}],
    "agents" => [
      {"execution_mode", "TEXT"},
      {"engine_session_id", "TEXT"},
      {"transcript_path", "TEXT"},
      {"git_rewrite_at", "TEXT"},
      {"current_tool", "TEXT"},
      {"turn_tool_count", "INTEGER"},
      {"waiting_since", "TEXT"},
      {"stopped_reason", "TEXT"},
      {"off_at", "TEXT"},
      {"off_by", "TEXT"},
      {"off_reason", "TEXT"},
      {"retired_at", "TEXT"},
      {"retired_by", "TEXT"},
      {"retired_reason", "TEXT"},
      {"continuous", "INTEGER"},
      {"story_id", "INTEGER"},
      {"epic_id", "TEXT"},
      {"issue_id", "TEXT"},
      {"mailbox_generation", "TEXT"},
      {"team_free_at", "TEXT"},
      {"turn_started_at", "TEXT"},
      {"declined_offer", "TEXT"},
      {"declined_offer_at", "TEXT"},
      {"declined_offer_count", "INTEGER"},
      {"provider_refusal", "TEXT"},
      {"provider_refused_at", "TEXT"},
      {"provider_retry_at", "TEXT"},
      {"tasks", "TEXT"}
    ],
    "analysis_runs" => [
      {"findings", "TEXT"},
      {"requested_by", "TEXT"},
      {"requester_agent_id", "TEXT"},
      {"orphaned", "INTEGER"},
      {"settled", "TEXT"},
      {"began_at", "TEXT"},
      {"start_commit", "TEXT"},
      {"start_tree_dirty", "INTEGER"},
      {"completed_commit", "TEXT"}
    ],
    "dependencies" => [{"provenance", "TEXT"}, {"in_code", "INTEGER"}],
    "devices" => [
      {"last_up_at", "TEXT"},
      {"load", "TEXT"},
      {"load_reported_at", "TEXT"},
      {"preview_tunnel_id", "TEXT"},
      {"preview_tunnel_secret", "TEXT"},
      {"provider", "TEXT"},
      {"provider_name", "TEXT"},
      {"provider_resource_id", "TEXT"},
      {"purpose", "TEXT"},
      {"token_hash", "TEXT"},
      {"token_last_used_at", "TEXT"},
      {"token_revoked_at", "TEXT"},
      {"fire_routine_id", "TEXT"},
      {"fire_token", "TEXT"}
    ],
    "doc_embeddings" => [{"package", "TEXT"}, {"version", "TEXT"}, {"model", "TEXT"}],
    "files" => [{"module_name", "TEXT"}],
    "project_configurations" => [
      {"architecture", "TEXT"},
      {"advisory_findings", "TEXT"},
      {"main_agent_cadence_seconds", "INTEGER"}
    ],
    "project_dependencies" => [{"checksum", "TEXT"}],
    "provisioning_steps" => [{"environment", "TEXT"}],
    "qa_invalidations" => [
      {"cause", "TEXT"},
      {"actor_id", "TEXT"},
      {"issue_id", "TEXT"},
      {"submission_ref", "TEXT"}
    ],
    "requirements" => [
      {"inputs_fingerprint", "TEXT"},
      {"owner_component_type", "TEXT"},
      {"node_scope", "TEXT"},
      {"issue_id", "TEXT"}
    ],
    "working_copies" => [
      {"machine_tool_docs", "TEXT"},
      {"browser_status", "TEXT"},
      {"browser_error", "TEXT"}
    ]
  }

  def up do
    for {table, columns} <- @columns,
        present = present(table),
        {column, type} <- columns,
        column not in present do
      execute("ALTER TABLE #{table} ADD COLUMN #{column} #{type}")
    end
  end

  def down, do: :ok

  defp present(table) do
    %{rows: rows} = repo().query!("SELECT name FROM pragma_table_info('#{table}')")
    List.flatten(rows)
  end
end
