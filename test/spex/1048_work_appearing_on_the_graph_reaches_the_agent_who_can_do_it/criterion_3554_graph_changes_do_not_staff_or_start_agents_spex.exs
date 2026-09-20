defmodule CodeMySpecSpex.Story1048.Criterion3554Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3554 — Graph changes never staff or start an agent.

  The checkout is connected and has a provider, but nobody has staffed an
  agent. Releasing real story work must leave the project's roster empty and
  the machine's process inventory exactly as it found it, while keeping the
  work visible for selection.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers,
    only: [given_a_staffed_checkout: 2, frame: 1, listing: 1]

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A graph change does not create its own workforce" do
    scenario "Work remains available on a connected checkout with no agent" do
      given_ "a connected checkout has no staffed agents", context do
        context = given_a_staffed_checkout(context, "spex_3554")
        context = ProjectStateFixtures.apply_project_kickoff(context)
        assert listing(context) == "No agents are running on this project."

        # Recorded rather than asserted empty. `Machine.running/0` is the
        # machine's registry, which is one process for the whole suite and
        # carries whatever every other criterion has running at this moment —
        # so `== []` is a claim about the suite, not about this project, and it
        # held only when this file ran alone. What this criterion is about is
        # what the release below *causes*, which is the difference.
        {:ok, Map.put(context, :running_before, Machine.running())}
      end

      given_ :synced_context_component

      given_ "a reviewed story is waiting to be released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refund posting without a staffed agent",
            description: "Work must wait for an existing agent to choose it",
            acceptance_criteria: ["A refund reaches the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        :ok = Fixtures.watch_graph(context.scope)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the story is released and the graph recomputes", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      then_ "the graph offers work without staffing or starting a process", context do
        {:reply, work, _} = GetNextRequirement.execute(%{}, frame(context))
        refute work.isError, response_text(work)
        assert response_text(work) =~ "review_file"
        assert listing(context) == "No agents are running on this project."
        assert Machine.running() == context.running_before
        {:ok, context}
      end
    end
  end
end
