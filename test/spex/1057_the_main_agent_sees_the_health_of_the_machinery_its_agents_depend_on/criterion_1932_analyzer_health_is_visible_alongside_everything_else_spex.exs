defmodule CodeMySpecSpex.Story1057.Criterion1932Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 1932 — Analyzer health is visible alongside everything else.

  Rule: one report answers "is it the agent or the machinery", analyzers
  included.

  An analyzer that died is machinery, the same as a harness that dropped its
  socket: every agent that waits on its result stalls, and each one looks
  individually stuck. If its state lives somewhere other than the report the
  main agent reads for machinery, the main agent reads the harnesses, sees them
  healthy, and goes after the agents.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Analyzer state appears in the machinery report beside the harnesses", criterion: 1932 do
    scenario "one analyzer failed, one completed, one never ran" do
      given_ "a checkout whose credo run died and whose exunit run completed", context do
        reply = join_working_copy(context, "/tmp/spex-1932", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        _agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-1932")

        _failed = Fixtures.failed_analysis_run(scope, "credo")
        _completed = Fixtures.completed_analysis_run(scope, "exunit")

        {:ok, Map.put(context, :scope, scope)}
      end

      when_ "the main agent looks at the machinery", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "check_machinery",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "the analyzers are in the same report as the harnesses", context do
        assert context.report =~ ~r/^harness/m and context.report =~ ~r/^analyzers:/m,
               """
               Analyzer health has to be read in the same place as the rest of
               the machinery. A main agent that sees healthy harnesses here and
               has to look elsewhere for analyzers goes after the agents.

               report:
               #{context.report}
               """

        {:ok, context}
      end

      then_ "the dead analyzer is called out as failed", context do
        assert analyzers(context.report) =~ ~r/credo[^\n]*FAILED/,
               """
               A credo run that did not finish is a gate nobody can answer, and
               the report has to say so in words, not leave it to be inferred
               from a missing line.

               analyzers section:
               #{analyzers(context.report)}
               """

        {:ok, context}
      end

      then_ "and the others say where they stand", context do
        section = analyzers(context.report)

        assert section =~ ~r/exunit[^\n]*last run completed/,
               "A completed analyzer names its run.\n\nanalyzers section:\n#{section}"

        assert section =~ ~r/spex[^\n]*has not run/,
               "An analyzer that never ran says so rather than vanishing.\n\nanalyzers section:\n#{section}"

        {:ok, context}
      end
    end
  end

  # The analyzers section of the report, up to the next section.
  defp analyzers(report) do
    report
    |> String.split(~r/^(?=\w+:)/m)
    |> Enum.find("", &String.starts_with?(&1, "analyzers:"))
  end
end
