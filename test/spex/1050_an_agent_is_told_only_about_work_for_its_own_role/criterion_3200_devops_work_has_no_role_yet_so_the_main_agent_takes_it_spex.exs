defmodule CodeMySpecSpex.Story1050.Criterion3200Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3200 — Devops work has no role yet, so the main agent takes it.

  What happens to work whose role does not exist. `Agent`'s own enum is
  `[:main, :product, :coding, :qa]` — there is no devops role — and devops work
  is real: environments, servers, deploys, the whole `run_devops_setup` path.

  The rule the story needs is that unroled work has a home rather than a gap.
  The main agent is that home, and it is the right one for a reason that
  outlives this case: it is the agent whose scope is the project rather than a
  checkout, so work that belongs to no checkout belongs to it.

  The second Then is what makes this a routing rule instead of a fallback. "Any
  agent will do" would satisfy the first half and put infrastructure work in
  front of a coding agent on one worktree — which would act on it, because it
  can, and change the project's servers from inside one checkout.

  3201 is the same work once a devops role exists, and the pair is what says
  this is a default rather than a permanent assignment.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work whose role does not exist goes to the main agent" do
    scenario "Devops work has no role yet, so the main agent takes it" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a main agent and a coding agent, and no devops agent", context do
        main = Fixtures.running_agent(context.scope, role: "main")
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        refute "devops" in Enum.map(Fixtures.list_agents(context.scope), &to_string(&1.role)),
               "the premise is that no devops agent exists"

        {:ok,
         context
         |> Map.put(:main, main.id)
         |> Map.put(:coding, coding.id)
         |> Map.put(:main_before, heard_count(context, main.id))
         |> Map.put(:coding_before, heard_count(context, coding.id))}
      end

      when_ "devops work appears on the project", context do
        :ok = Fixtures.enable_devops(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the main agent is told about it", context do
        assert heard_count(context, context.main) > context.main_before,
               """
               Devops work appeared and nobody was told.

               There is no devops role in `Agent`'s enum, so work of that kind
               has no queue of its own — and without a rule sending it
               somewhere, it is simply a gap: real work, on the graph, that no
               agent will ever be woken for.

               The main agent is the right home because its scope is the
               project rather than a checkout, which is exactly what devops
               work is about.
               """

        {:ok, context}
      end

      then_ "and no working-copy agent is told about it", context do
        refute_told_anything(
          context,
          context.coding,
          context.coding_before,
          """
          Infrastructure work was put in front of an agent that lives in one
          checkout.

          "Any agent will do" satisfies the half above and produces this: a
          coding agent on one worktree changing the project's servers, because
          it can and it was asked to. Whose work this is has to be a routing
          decision, not a fallback.
          """
        )

        {:ok, context}
      end
    end
  end
end
