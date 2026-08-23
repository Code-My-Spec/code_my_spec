defmodule CodeMySpecSpex.Story555.Criterion6237Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 6237 — Problems on files this session did not edit do
  not block the stop.

  Covers the new rule:

  > Blocking problems are scoped to the current (session_id,
  > agent_id). PostToolUse attributes each Write/Edit/MultiEdit/
  > NotebookEdit to (session_id, agent_id, agent_type, file_path);
  > the stop hook filters every analyzer's problems through that
  > set before deciding block/allow.

  Today the pipeline scopes by `Files.changed_since(started_at)` —
  any file with `mtime >= task.started_at` is in scope, regardless
  of which session/agent actually wrote it. A parallel session
  writing to disk (e.g. another agent thread rewriting a spec file)
  leaks into the current session's block decision. The new contract
  narrows the changed set to PostToolUse-attributed edits for this
  `(session_id, agent_id)` before running analyzers or consulting
  the Problems table.

  ## Surface

  - `POST /api/hooks/post-tool-use` — the agent's PostToolUse hook.
    Drives the same payload Claude Code delivers
    (`tool_name`, `tool_input.file_path`, `session_id`, optional
    `agent_id` / `agent_type`).
  - `POST /api/hooks/stop` — observes the block/allow decision after
    the filter.
  - `Environments.write_file/3` — memfs surface for the actual file
    edits (both session A's tracked file and the other session's
    untracked spec file).

  ## What this asserts

  Session A's stop must NOT block on a spec_validation finding for
  a spec file the other session wrote — even though that file's
  mtime is past `task.started_at` and would otherwise fall inside
  the changed-files window.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @session_a_impl_path "lib/example_context.ex"
  @other_session_spec_path ".code_my_spec/spec/code_my_spec/other_context.spec.md"

  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Stop hook filters analyzer problems by PostToolUse attribution" do
    scenario "spec_validation finding on an unattributed spec file is excluded for session A" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "session A rewrites its own impl and records the edit via PostToolUse", context do
        :ok =
          Environments.write_file(
            context.environment,
            @session_a_impl_path,
            "defmodule ExampleContext do\n  @moduledoc false\n  def noop, do: :ok\nend\n"
          )

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/post-tool-use", %{
          "session_id" => context.session_id,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => @session_a_impl_path}
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      given_ "a parallel session leaks a bogus spec file into the same memfs without attribution",
             context do
        # No PostToolUse for session A on this file — it stands in for an
        # artifact written by some other process or parallel session.
        # The bogus spec deliberately omits the required Functions /
        # Delegates section so `spec_validation` would surface a
        # blocking problem if the analyzer were allowed to run against
        # it for this stop.
        :ok =
          Environments.write_file(
            context.environment,
            @other_session_spec_path,
            "# OtherContext\n\n## Type\n\ncontext\n\nIntent prose only — no Functions section.\n"
          )

        # The file is really there, and really invalid. Both assertions below
        # are refutes — and an allowed stop answers `%{}`, which is `Hooks.Stop`
        # returning from `allow/2`, so `nil != "block"` and `"" =~ path` hold
        # for a run with nothing to filter as readily as for one that filtered
        # correctly. This is what makes the difference observable: there was a
        # blocking-shaped finding available, and it was left out.
        assert {:ok, contents} =
                 Environments.read_file(context.environment, @other_session_spec_path)

        refute contents =~ "## Functions",
               "the other session's spec has to be invalid, or there is nothing for the " <>
                 "stop hook to have filtered"

        {:ok, context}
      end

      when_ "the stop hook fires for session A", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "exunit" => fixture_path("exunit.json"),
                "compile" => fixture_path("compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is not blocked on the other session's spec_validation finding", context do
        refute context.response["decision"] == "block",
               "expected the other-session spec_validation finding to be filtered out for session A, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the other-session file path does not appear in any block reason", context do
        # Anchor refute: if the implementation regresses such that a
        # block IS produced, this surfaces *which* file leaked across
        # session boundaries — not just that something blocked.
        reason = context.response["reason"] || ""

        refute reason =~ @other_session_spec_path,
               "expected the other-session file to be absent from any block reason, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
