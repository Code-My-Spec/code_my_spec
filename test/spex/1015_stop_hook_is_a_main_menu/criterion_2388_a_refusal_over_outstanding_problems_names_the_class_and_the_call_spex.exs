defmodule CodeMySpecSpex.Story1015.Criterion2388Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2388 — A refusal over outstanding problems names the class
  and the call.

  The hook today answers one question — may you stop? — and says no by
  naming findings. It never says what to do instead. An agent whose own
  area is clear has to guess what class of work is available, and guessing
  is what this story exists to stop.

  The rule:

  > Every stop the hook refuses names a class of available work and the
  > tool call that opens it.

  So a refusal over problems must say two things a compiler-diagnostics
  dump does not: that the class is *problems*, and that `list_problems` is
  what opens it. Naming the finding is not naming the class — the agent
  reading it still has to know which of four buckets it is in and which
  tool to reach for.

  ## Surface

  `POST /api/hooks/stop`. The task prompt inferred "MCP tool" from the
  `When` step ("the agent attempts to stop"), which is wrong: stopping is
  the hook endpoint, and the surfaces reference maps it to HTTP. The
  `x-harness-id` header is the routing key — `x-working-dir` appears in
  the older quick-reference and is no longer on the wire.

  ## Expected to be red

  Nothing renders a class label or a tool call today. `ProblemRenderer`
  produces the findings and the latch explanation, so the assertions below
  encode the criterion rather than the current output, which is the point.

  Reuses story 555's `pipeline_compile_error` fixtures to produce a
  genuine refusal — the block has to be real for the question "what does a
  refusal say" to mean anything.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A refusal names the class of work and the call that opens it" do
    scenario "outstanding problems block the stop and the reason names list_problems" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent leaves a finding behind in a file it edited", context do
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the hook refuses the stop", context do
        assert context.response["decision"] == "block",
               "an outstanding finding must refuse the stop, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the response names problems as the class of available work", context do
        reason = context.response["reason"] || ""

        assert reason =~ ~r/\bproblems\b/i,
               "a refusal must name the class, not only the findings. " <>
                 "Naming the finding leaves the agent to work out which of four " <>
                 "buckets it is in. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the response names the call that opens it", context do
        reason = context.response["reason"] || ""

        assert reason =~ "list_problems",
               "naming the class without naming the call leaves the agent where it " <>
                 "was — it now knows what kind of work exists and not how to see it. " <>
                 "Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
