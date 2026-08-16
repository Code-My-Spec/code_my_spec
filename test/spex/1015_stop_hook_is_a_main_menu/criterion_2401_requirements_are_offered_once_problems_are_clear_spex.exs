defmodule CodeMySpecSpex.Story1015.Criterion2401Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2401 — Requirements are offered once problems are clear.

  The rule:

  > Live classes are offered in a fixed order: problems before requirements.

  The other half of the tier. 2400 shows problems winning while both are live;
  this shows the tier *falling through* rather than going quiet — a clean tree
  with work outstanding is the ordinary state of a project, and it is exactly
  the state in which the agent was left guessing.

  This is the case that produced the story. The framework queue emptied, nothing
  said "there is other work and here is how to find it", and the agent invented
  audits instead — the last of which returned ~900 "orphan components" that are
  not defects at all.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`. Clean pipeline via the
  `clean` cassette and the `pipeline_clean_run/` fixture directory, paired as
  the project playbook prescribes. The synced component leaves requirements
  unsatisfied, which is what makes the second tier live.

  Note this deliberately does **not** use `:synced_context_in_satisfied_project`
  — that given is 2393's, where nothing is outstanding and the stop is allowed.
  The difference between the two is the whole content of this criterion.

  Expected red: nothing names a call today.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Requirements are the directive when nothing is broken" do
    scenario "no problems, requirements outstanding" do
      given_ :synced_context_component
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

      then_ "the agent is sent to its next requirement", context do
        reason = context.response["reason"] || ""

        assert reason =~ "get_next_requirement",
               "a clean tree with work outstanding is the ordinary state of a " <>
                 "project, and saying nothing in it is what left the agent inventing " <>
                 "audits. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
