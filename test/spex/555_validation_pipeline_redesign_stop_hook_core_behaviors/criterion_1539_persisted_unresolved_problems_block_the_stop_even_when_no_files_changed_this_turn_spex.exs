defmodule CodeMySpecSpex.Story555.Criterion1539Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 1539 — Persisted unresolved problems block the stop even
  when no files changed this turn.

  Same real-contract flow as criterion 5097 (sync, then a task started
  after every file's updated_at so `Files.changed_since` returns []),
  except a problem is already on the books from an earlier run. 5097
  proves the pipeline skips compile/credo/tests when nothing changed;
  this proves that skip does not also mean "nothing can block" — a
  problem persisted before this turn still counts.

  The seeded problem's source is `exunit`, not `credo`: `credo`
  defaults to `:block_changed` (lib/code_my_spec/configurations/project_configuration.ex),
  which reads any problem on an unchanged file as advisory regardless
  of when it was recorded — a different axis (changed vs. not) than
  the one this criterion is about (recorded now vs. recorded earlier).
  `exunit` defaults to `:block_all`, so it isolates persistence-across-turns
  from the changed/unchanged distinction 5100 and the `:block_changed`
  criteria already cover.

  ## Why `Fixtures.problem_fixture` here is not a shortcut around the
  contract

  This criterion is explicitly about the downstream decision (does an
  already-persisted, unresolved problem block a stop that touches
  nothing), not about how a problem gets persisted in the first place
  — an end-to-end failing-test run is covered elsewhere. Seeding the
  row directly is the documented exception in `bdd/spex/boundaries.md`.

  ## Why a PostToolUse attribution is still recorded, even though
  nothing changes afterward

  `check_blocking_problems/5` demotes any blocking finding whose file
  is unattributed to the current session (`split_unattributed/2`,
  criterion 1538/6237/1540's rule) regardless of analyzer mode — a
  problem on a file this session never touched does not block just
  because the mode says `:block_all`. This criterion is about a turn
  with *no new writes*, not a session that never wrote the file at
  all, so the session records its PostToolUse attribution for the file
  once, then the stop that follows makes no further edits.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Persisted unresolved problems block the stop even when no files changed this turn" do
    scenario "a previously-recorded test failure blocks a stop with no new writes" do
      given_ :synced_context_component
      given_ :context_implementation_task_started

      given_ "the session recorded its edit to the component's file via PostToolUse", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/post-tool-use", %{
          "session_id" => context.session_id,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => @impl_path}
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      given_ "a previous run persisted an unresolved test failure on that file", context do
        Fixtures.problem_fixture(context.scope, %{
          source: "exunit",
          source_type: :test,
          file_path: @impl_path,
          component_id: context.component.id,
          line: 3,
          message: "test noop/0 raises RuntimeError",
          category: "failure",
          rule: nil
        })

        {:ok, context}
      end

      when_ "the stop hook fires with no additional file writes", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block",
               "a persisted unresolved problem with no new writes must still block, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the persisted problem is named in the block reason", context do
        reason = context.response["reason"] || ""

        assert reason =~ "test noop/0 raises RuntimeError",
               "expected the persisted problem's message in the block reason, got:\n#{reason}"

        {:ok, context}
      end
    end
  end
end
