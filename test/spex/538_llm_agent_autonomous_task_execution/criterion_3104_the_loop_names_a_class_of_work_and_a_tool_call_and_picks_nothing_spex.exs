defmodule CodeMySpecSpex.Story538.Criterion3104Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 3104 — The loop names a class of work and a tool call, and
  picks nothing.

  Covers `Validation.Menu.render/4`'s directive: when requirements are the
  live class, the directive names the count and the tool that opens it —
  `get_next_requirement` — and stops there. It does not call `start_task` on
  the agent's behalf; the graph decides what is available and the agent
  chooses, the same distinction criterion 3108 asserts for a wake.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
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

  # See criterion 3059's note: an uncassetted `validate_stop` runs a real
  # `mix compile` and a real recursive `mix spex`, neither of which is what
  # this criterion is about.
  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  spex "A refusal names one class of work and its tool, never a particular requirement" do
    scenario "requirements are the only live class" do
      given_ "the project chain is past kickoff, so story work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the story interview is complete and BDD work is available", context do
        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, context.story,
            persona_id: context.persona_id
          )

        {:ok, context}
      end

      given_ "a coding agent, working, with nothing blocking it", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: context.scope.active_working_copy_id, working: true},
            frame
          )

        {:reply, _next, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :coding, coding.id)}
      end

      when_ "the coding agent's stop hook fires with actionable work waiting", context do
        use_cmd_cassette "clean", record: :none do
          :ok = Fixtures.end_turn(context.scope, context.coding, @end_turn_opts)
        end

        {:ok, Map.put(context, :said, latest(context.scope, context.coding))}
      end

      then_ "the refusal names the requirements class and its tool", context do
        assert context.said =~ ~r/requirement/i,
               "expected the refusal to name the requirements class, got: #{context.said}"

        assert context.said =~ "get_next_requirement",
               "expected the refusal to name the tool that opens the class, got: #{context.said}"

        {:ok, context}
      end

      then_ "and it does not pick a particular requirement to start", context do
        refute context.said =~ "start_task",
               "the refusal named a specific requirement to start rather than the class and " <>
                 "its tool. The graph decides what is available; the agent chooses which to " <>
                 "take. Got: #{context.said}"

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
