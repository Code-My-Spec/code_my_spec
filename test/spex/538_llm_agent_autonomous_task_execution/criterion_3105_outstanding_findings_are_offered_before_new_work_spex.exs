defmodule CodeMySpecSpex.Story538.Criterion3105Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 3105 — Outstanding findings are offered before new work.

  Covers `Validation.Menu`'s ordering: `[:problems, :task, :requirements]`.
  Problems outrank requirements, and the tally that follows the directive
  never carries a tool name for the classes it merely counts — so when
  problems lead, `get_next_requirement` does not appear anywhere in the
  response at all, not even as a secondary mention.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.SetWorkingCopyLoop
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  spex "list_problems outranks get_next_requirement when both are live" do
    scenario "problems and requirements are both outstanding for a coding agent" do
      given_ "the project chain is past kickoff, so story work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component

      # `:coding` is one of `@problem_roles` — the only roles a problems class
      # counts for — so this premise needs that role specifically, not just any
      # agent.
      given_ "a coding agent, working, with an enforceable problem recorded against it",
             context do
        coding = Fixtures.running_agent(context.scope, role: "coding")

        # A problem whose file was never synced is indistinguishable from one
        # whose file has since been deleted, and gets cleared the same way —
        # see Reconciler's own note on `patch_file_path/1`. Every working
        # sibling that seeds a problem (8197, 8201, 8202, 3478) writes the
        # file first for exactly this reason; this scenario was missing it.
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/accounts.ex",
            "defmodule MyApp.Accounts do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        Fixtures.record_problem(context.scope, "credo", %{
          severity: :error,
          component_id: context.component.id
        })

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: context.scope.active_working_copy_id, working: true},
            frame
          )

        {:reply, _next, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :coding, coding.id)}
      end

      when_ "the coding agent's stop hook fires", context do
        use_cmd_cassette "clean", record: :none do
          :ok = Fixtures.end_turn(context.scope, context.coding, @end_turn_opts)
        end

        {:ok, Map.put(context, :said, latest(context.scope, context.coding))}
      end

      then_ "the refusal directs the agent to list_problems", context do
        assert context.said =~ "list_problems",
               "expected the problem to outrank requirements and be named first, got: " <>
                 context.said

        {:ok, context}
      end

      then_ "and it does not direct the agent to get_next_requirement", context do
        refute context.said =~ "get_next_requirement",
               "requirements should only be tallied, without its tool name, while a problem " <>
                 "leads — starting new work on a broken tree is exactly what the ordering " <>
                 "exists to prevent. Got: #{context.said}"

        {:ok, context}
      end
    end
  end

  defp latest(scope, agent_id) do
    scope
    |> Fixtures.messages_to_agent(agent_id)
    |> List.last()
    |> inspect()
  end
end
