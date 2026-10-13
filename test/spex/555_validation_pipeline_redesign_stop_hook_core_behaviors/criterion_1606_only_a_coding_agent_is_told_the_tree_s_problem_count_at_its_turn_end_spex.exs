defmodule CodeMySpecSpex.Story555.Criterion1606Spex do
  @moduledoc """
  Story 555 — Validation pipeline redesign: stop hook core behaviors.
  Criterion 1606 — Only a coding agent is told the tree's problem count at its
  turn end.

  John, a31f1cd6 step 4b: "holds_problems is coding only". The tree's findings
  are coding's to fix, so a coding agent's turn-end menu counts them and names
  `list_problems`; main's does not.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  # A run that found a failing spec in a file neither agent touched.
  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    exunit_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/exunit.json"),
    spex_output_file: Path.expand("test/fixtures/validation/pipeline_spex_failure/spex.jsonl"),
    # The run lands before the turn ends: a turn end starts no analysis.
    await: true
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Only a coding agent is told the tree's problem count at its turn end", criterion: 1606 do
    scenario "A failing spec is counted in the coder's turn-end menu and not in main's" do
      given_ :synced_context_component

      # The failing spec the recorded run names. A finding on a file that is
      # not on disk is cleared by the next sync, which every stop runs.
      given_ "the failing spec is in the working copy", context do
        :ok =
          CodeMySpec.Environments.write_file(
            context.environment,
            "test/spex/example_context_spex.exs",
            "defmodule ExampleContextSpex do\nend\n"
          )

        {:ok, context}
      end

      given_ "a continuous coding agent and a continuous main agent on a working copy", context do
        use_cmd_cassette "clean", record: :none do
          Fixtures.land_outputs(context.scope, @end_turn_opts)
        end

        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        context = put_to_work(context)

        # Each holding a task: an agent holding none is offered work at its
        # turn end rather than handed the menu (`StopDecision.continuing/4`).
        context =
          context
          |> start_agent_task(coder.id, %{
            requirement_name: "implementation_file",
            entity_type: "component",
            entity_id: to_string(context.component.id)
          })

        # Main on one of its own: the project's technical strategy.
        main_frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: main.id}
        }

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "technical_strategy",
              entity_type: "project",
              entity_id: to_string(context.scope.active_project_id)
            },
            main_frame
          )

        refute started.isError,
               "main must hold a task, or its turn end offers work instead of a menu: " <>
                 response_text(started)

        {:ok,
         Map.merge(context, %{
           coder: coder.id,
           main: main.id,
           coder_before: heard_count(context, coder.id),
           main_before: heard_count(context, main.id)
         })}
      end

      when_ "each turn ends on a run that found a failing spec", context do
        :ok =
          use_cmd_cassette "clean", record: :none do
            :ok = Fixtures.end_turn(context.scope, context.coder)
            :ok = Fixtures.end_turn(context.scope, context.main)
          end

        {:ok, context}
      end

      then_ "the coding agent is told the problem count and how to see them", context do
        said = said_since(context, context.coder, context.coder_before)

        assert Enum.any?(said, &(&1 =~ "list_problems")),
               "the coding agent was not told the tree's problems at its turn end: #{inspect(said)}"

        {:ok, context}
      end

      then_ "and the main agent is not", context do
        said = said_since(context, context.main, context.main_before)

        refute Enum.any?(said, &(&1 =~ "list_problems")),
               "main was handed the tree's problems, which are coding's to fix: #{inspect(said)}"

        {:ok, context}
      end
    end
  end
end
