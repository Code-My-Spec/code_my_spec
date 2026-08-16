defmodule CodeMySpecSpex.Story1015.Criterion2393Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2393 — An empty menu is a terminal state.

  The rule:

  > An agent with no work in any class is allowed to stop.

  This is the half of the menu that says nothing. When requirements, issues,
  problems and owed input are all empty, the answer is that there is nothing
  to do — and the hook has to be willing to say so.

  John's account of why it matters is the reason this criterion exists at all:
  the framework queue emptied, nothing said so, and the agent kept sweeping
  surfaces looking for work rather than stopping. The last of those returned
  ~900 "orphan components" that are not defects. A menu with no terminal state
  does not produce rest; it produces invented work.

  ## What this does and does not cover

  A clean pipeline outside continuous mode. It may well pass today — a clean
  run already allows the stop — and that is worth knowing rather than assuming,
  because it locates the gap precisely: if this is green, the terminal state
  already holds and what is missing is only the continuous-mode case, where the
  hook currently never allows a stop and `tap_out` is the sole escape.

  Written as the criterion states it rather than as a prediction. If it is
  green on the first run, that is a finding about scope, not a spec that failed
  to be useful.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`. Clean pipeline via the
  `clean` cassette and the `pipeline_clean_run/` fixture directory — the pairing
  the project cassette playbook prescribes. `compile.jsonl` is 0 bytes on
  purpose: `Compile.execute` reads that as no diagnostics, and writing `[]` or
  `{}` into it breaks that.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent with nothing to do is allowed to stop" do
    scenario "no class of work has anything for this working copy" do
      given_ :synced_context_in_satisfied_project
      given_ :context_spec_task_started

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => fixture_path("compile.jsonl"),
                "exunit" => fixture_path("exunit.json"),
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the hook allows the stop", context do
        refute context.response["decision"] == "block",
               "an empty menu must be a terminal state; a hook that cannot say " <>
                 "\"nothing to do\" produces invented work instead of rest. Got: " <>
                 "#{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the response directs the agent to no tool call", context do
        reason = context.response["reason"] || ""

        refute reason =~ "get_next_requirement",
               "nothing is outstanding, so nothing should be recommended. Got:\n#{reason}"

        refute reason =~ "list_problems",
               "nothing is outstanding, so nothing should be recommended. Got:\n#{reason}"

        refute reason =~ "list_issues",
               "nothing is outstanding, so nothing should be recommended. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
