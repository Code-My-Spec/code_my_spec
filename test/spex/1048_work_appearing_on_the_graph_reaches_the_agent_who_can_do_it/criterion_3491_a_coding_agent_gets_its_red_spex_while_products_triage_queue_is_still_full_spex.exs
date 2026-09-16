defmodule CodeMySpecSpex.Story1048.Criterion3491Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3491 — A coding agent gets its red spex while product's triage
  queue is still full.

  Watched on 2026-09-15: a coding agent on a checkout carrying five red spex
  criteria in its own role reported "the graph holds no work for its role", and
  the next-requirement answer was `TriageIssues` and nothing else. Triaging the
  queue by hand opened `ComponentCode`, `FixBddSpecs`, `QaStory` and
  `FixIssues`; four fresh issues closed it again. Nothing about the coding work
  changed across either transition — the only variable was the depth of a queue
  belonging to product.

  `issues_triaged` is product's, `qa_setup` waits on it, and
  `project.qa_setup -> story.component_linked` carries that into every story's
  chain. A node is blocked when any transitive prerequisite is unsatisfied,
  whoever owns it, so one untriaged issue made every story's coding work
  unactionable for a role that could not clear it.

  ## The premise has to carry real coding work

  An earlier version of this brought the project fully green before asking. It
  passed against the unfixed code, because on a green project coding has nothing
  outstanding — "coding sees nothing" was true either way and the assertion could
  not tell a clamp from an empty board. `apply_up_to_analysis/1` is the chain
  minus the green analysis run, which is the step that satisfies
  `bdd_specs_passing`, so it leaves a real named piece of coding work on the
  board. That is the only state where this question has an answer worth reading.

  ## Asked through the tool an agent actually calls

  The `when_` drives `GetNextRequirement`, because "asks what it should work on"
  is that tool and the role is read from `frame.assigns[:agent_id]`. Asserting
  against `Requirements.actionable_for_role/2` instead would test a function no
  agent calls, and would pass while the tool an agent does call still answers
  `TriageIssues`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is offered the work of its own role, whatever another role's queue looks like" do
    scenario "A coding agent gets its red spex while product's triage queue is still full" do
      given_ "a project with a story whose BDD specs are failing", context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)

        # Everything coding owns except the one thing this criterion is about.
        #
        # `apply_up_to_analysis/1` withholds the analysis run entirely, which
        # leaves `tests_passing` outstanding on an unbuilt component as well as
        # `bdd_specs_passing` on the story — and `ComponentCode` sorts ahead, so
        # the answer below named a component rather than the failing specs.
        # Stamping every source but `spex` satisfies the first and leaves the
        # second, which is the state the Given actually describes.
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        :ok = Fixtures.settle_graph(context.scope)

        assert Fixtures.actionable_names(context.scope, :coding) == ["bdd_specs_passing"],
               """
               The premise is a story whose BDD specs are failing and nothing
               else outstanding for coding, and that is not the board.

               More than that and the answer below can name other coding work
               and still satisfy the assertion without the failing specs ever
               being offered. Less and there is nothing for the clamp to
               withhold, so the scenario cannot fail.

               Coding-actionable now: #{inspect(Fixtures.actionable_names(context.scope, :coding))}
               """

        {:ok, context}
      end

      given_ "a coding agent running on the working copy that carries them", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")

        {:ok, Map.put(context, :coding, coding.id)}
      end

      given_ "incoming issues that nobody has triaged yet", context do
        # Filed through the real tool rather than seeded, so the issue lands
        # `incoming` the way a QA agent's would — the state the triage gate
        # actually reads.
        {:reply, _filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something product has not looked at yet",
              description: "filed, untriaged, and none of coding's business",
              severity: "medium"
            },
            %Frame{assigns: %{current_scope: context.scope}}
          )

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      when_ "the coding agent asks what it should work on", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.coding}
        }

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :answer, response_text(response))}
      end

      then_ "it is offered the failing specs", context do
        assert context.answer =~ "bdd_specs_passing",
               """
               The coding agent asked for its work and was not offered the
               failing specs on its own checkout.

               This is the half that cannot be satisfied by answering nothing.
               A clamp that empties coding's queue and a board with no coding
               work on it are indistinguishable from the refutation below
               alone, which is why the pair is stated in this order.

               Answered with:
               #{context.answer}
               """

        {:ok, context}
      end

      then_ "and it is not offered the triage, which is product's work", context do
        refute context.answer =~ "issues_triaged",
               """
               Coding was offered `issues_triaged`, which belongs to product and
               which a coding agent cannot clear.

               Offering a role work it has no way to do is the same defect as
               withholding the work it can: either way the agent's next turn is
               spent on something that will not move.

               Answered with:
               #{context.answer}
               """

        {:ok, context}
      end
    end
  end
end
