defmodule CodeMySpecSpex.Story726.Criterion2205Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 2205 — The QA role carries start_analysis, including paths to
  scope a run to specific files, so a QA agent can run a focused test through
  the analysis queue and its result is recorded against that run.

  Title-only criterion; no scenario was recorded against it. Encoded as the
  mechanical reading of its own text: a QA agent can reach start_analysis at
  all (the tool is on the QA role's own list, not just coding's), scope a run
  to one file rather than the whole suite, and read that specific run's own
  result back afterward rather than some other run's.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.RecordedAnalysis
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  defp frame(context), do: %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

  spex "A QA agent scopes an analysis run to one file and reads its own result back",
    criterion: 2205 do
    scenario "A focused exunit run is admitted, scoped, and its output is recorded against it" do
      given_ "a started qa_complete task", context do
        # given: already true — `setup :setup_qa_story_task` carries a QA-role
        # agent with an active qa_complete task. Every criterion in this story
        # needs that, so it is scaffolding rather than subject.
        {:ok, context}
      end

      given_ "exunit's recorded output for a focused run", context do
        {:ok,
         attach_recorded_analysis(context,
           exunit: "test/fixtures/validation/pipeline_clean_run/exunit.json"
         )}
      end

      when_ "the agent calls start_analysis for exunit, scoped to one file", context do
        reply =
          ToolLibrary.run(
            "start_analysis",
            %{source: "exunit", paths: ["test/code_my_spec/some_focused_test.exs"]},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        {:ok,
         context |> Map.put(:start_reply, reply) |> Map.put(:start_text, response_text(reply))}
      end

      then_ "the run is admitted, not refused for being scoped or for the agent's role",
            context do
        assert match?({:ok, _}, context.start_reply),
               """
               A QA agent's scoped exunit run was refused.

               #{context.start_text}
               """

        refute context.start_text =~ ~r/not an analyzer|is not a role|not allowed/i,
               "the run was refused on a ground other than admission failing outright: #{context.start_text}"

        [_, run_id_str] = Regex.run(~r/Run (\d+) admitted/, context.start_text)
        {:ok, Map.put(context, :run_id, String.to_integer(run_id_str))}
      end

      when_ "the agent reads that specific run's output back", context do
        reply =
          ToolLibrary.run(
            "get_analysis_output",
            %{run_id: context.run_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        {:ok,
         context |> Map.put(:output_reply, reply) |> Map.put(:output_text, response_text(reply))}
      end

      then_ "the result is recorded against that run, scoped, not the whole suite", context do
        assert match?({:ok, _}, context.output_reply),
               "could not read back the run named in start_analysis's own reply: #{context.output_text}"

        page = Jason.decode!(context.output_text)

        assert page["run_id"] == context.run_id,
               "get_analysis_output returned a different run than the one start_analysis admitted"

        assert page["source"] == "exunit"

        assert page["kind"] == "partial",
               "a run scoped to one file must be recorded as partial, not a full sweep: #{inspect(page)}"

        assert page["output_available"] == true,
               "the focused run's own output was not recorded against its run id: #{inspect(page)}"

        {:ok, context}
      end
    end
  end
end
