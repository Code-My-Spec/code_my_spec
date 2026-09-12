defmodule CodeMySpecSpex.Story1058.Criterion3313Spex do
  @moduledoc """
  Story 1058 — The main agent reads what its agents cannot.
  Criterion 3313 — The main agent sees past the edge of a role's tool list.

  Rule: the main agent's reach is the project's, not a role's.

  The observed need, in the story's own words: a product agent asked to group
  ready stories into an epic reasoned correctly to "one ready story sits outside
  every epic", could not name which, and stopped. The answer came from a
  database query typed by a person.

  Note what did *not* go wrong. The agent was not confused and did not give up
  early; it got as far as its tools allowed and then correctly refused to guess.
  That is the failure this story addresses — a role doing exactly what it should
  and the work stopping anyway.

  ## The surface makes "does not depend on the role" literal

  `run_script` takes the agent it runs as, and the sandbox binds only what that
  agent's row carries. So the same script, run as the product agent and as the
  main agent, is precisely the criterion's two halves: the role cannot answer
  it, and the main agent can.

  A scenario that asked the main agent alone would assert the easy half and miss
  the point — the claim is comparative.

  ## What it needs that nothing has

  No tool exposes story-to-epic membership. `list_epics` lists epics and
  `assign_story_to_epic` writes one, and neither answers "which ready story is
  in none of them". So this is red on a missing capability rather than on a
  scoping bug, which is what criterion 3329 is about reporting.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @script """
  local orphans = {}
  for _, story in ipairs(ready_stories_without_epic({})) do
    table.insert(orphans, story.title)
  end
  return table.concat(orphans, ", ")
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question past the edge of a role is still answerable" do
    scenario "one ready story sits outside every epic" do
      given_ "ready stories, all in an epic except one", context do
        reply = join_working_copy(context, "/tmp/spex-3313", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        epic = Fixtures.epic_fixture(scope, %{title: "Billing"})

        for title <- ["Invoices export", "Refunds reconcile"] do
          story = Fixtures.authored_story(scope, title)
          :ok = Fixtures.put_story_in_epic(scope, story, epic)
          :ok = Fixtures.mark_story_ready(scope, story)
        end

        orphan = Fixtures.authored_story(scope, "Dunning emails go out")
        :ok = Fixtures.mark_story_ready(scope, orphan)

        product = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-3313")
        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3313")

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:product, product)
         |> Map.put(:main, main)}
      end

      when_ "the same question is asked as the product agent and as the main agent",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, as_product, _frame} =
          Fixtures.run_script(%{script: @script, agent_id: context.product.id}, frame)

        {:reply, as_main, _frame} =
          Fixtures.run_script(%{script: @script, agent_id: context.main.id}, frame)

        {:ok,
         context
         |> Map.put(:as_product, response_text(as_product))
         |> Map.put(:as_main, response_text(as_main))}
      end

      then_ "the main agent can name the story", context do
        assert context.as_main =~ "Dunning emails go out",
               """
               The main agent cannot answer a question about its own project's
               epics either.

               This is the observed failure: a product agent reasoned correctly
               to "one ready story sits outside every epic", could not name
               which, and stopped. The answer came from a person typing a
               database query.

               Nothing exposes story-to-epic membership — `list_epics` lists
               epics and `assign_story_to_epic` writes one, and neither answers
               this. The main agent needs the reading that no role carries.

               as main:
               #{context.as_main}
               """

        {:ok, context}
      end

      then_ "and the product role still cannot", context do
        refute context.as_product =~ "Dunning emails go out",
               """
               The product role can answer it after all, so this scenario proves
               nothing about the main agent's reach.

               The claim is comparative: a role stops at the edge of its tools
               and the main agent does not. If both can, the criterion is about
               a capability everybody should simply have — which is a different
               and easier story, and one this spex would be silently passing.

               as product:
               #{context.as_product}
               """

        {:ok, context}
      end
    end
  end
end
