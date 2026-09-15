defmodule CodeMySpecSpex.Story1048.Criterion3295Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3295 — Work inside my role and my copy wakes me.

  Both filters satisfied at once, which is the positive case 3190 is the
  negative of. 3190 asserts that failing either filter means silence; this
  asserts that passing both means a wake — and an implementation can satisfy
  3190 by never waking anybody.

  The second Then is the one that is not implied by the first. An agent woken
  and then handed different work is being routed, and the routing is by
  something other than the graph. That is the orchestrator this project
  declined — in John's own words on story 538, "I'm dubious our orchestrator
  will make better decisions than the model" — so the wake has to lead to the
  work that caused it rather than to a decision somebody else made.

  Checked against the story that triggered the wake by name, because "some work
  was offered" is true of any menu and says nothing about routing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers, only: [warm_graph: 1]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is woken only by work inside its own role and checkout" do
    scenario "Work inside my role and my copy wakes me" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a context component with no children, spec through review already done",
            context do
        module_name = "WorkRoutingContext"

        :ok =
          Environments.write_file(
            context.environment,
            Content.spec_path(module_name),
            Content.context_spec(module_name, type: "context", dependencies: [])
          )

        :ok =
          Environments.write_file(
            context.environment,
            Content.impl_path(module_name),
            Content.impl_file(module_name)
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/spec/#{Macro.underscore(module_name)}/design_review.md",
            """
            # #{module_name} Design Review

            ## Overview

            Reviewed #{module_name} with no children. Sound architecture for a
            placeholder bounded context.

            ## Architecture

            - Separation of concerns is appropriate for a single-component context.

            ## Integration

            - No integration points with other contexts.

            ## Conclusion

            Ready for implementation. No outstanding action items.
            """
          )

        :ok =
          Environments.write_file(
            context.environment,
            "test/#{Macro.underscore(module_name)}_test.exs",
            """
            defmodule #{module_name}Test do
              use ExUnit.Case, async: true

              test "placeholder" do
                assert true
              end
            end
            """
          )

        {:ok, sync_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        # "Already done" has to include the suites having run. `tests_passing`
        # reads the run ledger rather than the test file — "zero problems
        # because the suites never ran" stopped being satisfiable at v1.5.36 —
        # so writing a test file leaves this component's own work open, and
        # component work outranks the story's. The wake then arrived correctly
        # and `get_next_requirement` answered with a `ComponentCode` task for
        # this component instead of the released story, which reads exactly
        # like the routing defect this criterion exists to catch.
        #
        # Stamped after the last file lands, matching
        # `FullSatisfactionFixtures.apply_fresh_analysis_runs/1`. Releasing the
        # story later moves no file, so the fingerprint stays current.
        Fixtures.fresh_analysis_runs(context.scope)

        component = Fixtures.get_component_by_module_name(context.scope, module_name)
        {:ok, Map.put(context, :component, component)}
      end

      given_ "a story interviewed and linked, but not yet released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refunds reach the ledger",
            description: "Interviewed and waiting to be released",
            acceptance_criteria: ["A refund lands on the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "a coding agent idle on its assigned working copy", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work() |> warm_graph()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "a story on that copy becomes ready for coding", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :said, said_since(context, context.coding, context.before))}
      end

      then_ "the coding agent is woken", context do
        refute context.said == [],
               """
               Work passing both filters — this agent's role, this agent's
               checkout — woke nobody.

               3190 asserts that failing either filter means silence, and an
               implementation that never wakes anybody satisfies it perfectly.
               This is the criterion that rules that out.
               """

        {:ok, context}
      end

      then_ "and the work it is given is the work that appeared", context do
        {:reply, reply, _frame} = GetNextRequirement.execute(%{}, frame(context))
        offered = response_text(reply)

        # By id, because that is the identity the menu actually carries. Every
        # offer names `entity_type` and `entity_id` and no offer has ever
        # carried a story title, so matching on the title asserted against
        # text the surface does not emit — it failed on a correctly routed
        # wake exactly as it would on a misrouted one. The id is also the
        # stricter check: two stories can share a title.
        assert offered =~ "entity_type=`story`, entity_id=`#{context.story.id}`",
               """
               The agent was woken by one story and offered different work.

               Being woken and then routed elsewhere is somebody deciding what
               this agent does, which is the orchestrator this project declined
               — "I'm dubious our orchestrator will make better decisions than
               the model". The graph holds the ordering; the wake is a
               doorbell, and it has to open onto the thing that rang it.

               woken by: #{context.story.title} (story #{context.story.id})
               offered:
               #{offered}
               """

        {:ok, context}
      end
    end
  end
end
