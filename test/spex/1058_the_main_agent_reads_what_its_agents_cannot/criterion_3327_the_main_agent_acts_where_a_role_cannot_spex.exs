defmodule CodeMySpecSpex.Story1058.Criterion3327Spex do
  @moduledoc """
  Story 1058 — The main agent reads what its agents cannot.
  Criterion 3327 — The main agent acts where a role cannot.

  Rule: the wider scope is a working scope, not a reading one.

  3313 says the main agent can *see* past a role's tool list. This says it can
  finish the job — "both read and write what the work requires" is the
  criterion's own phrasing, and the distinction is not academic: the observed
  failure had a product agent that could work out what needed doing and could
  not do it, which is the same place a read-only main agent lands one step
  later.

  A main agent that can only read turns every gap into a report. That is the
  shape criterion 3321 on story 1057 already rejects for machinery faults, and
  it is the same mistake here: correct, safe, and nothing ever gets finished.

  ## Where the scenario puts the line

  A story needs assigning to an epic. The *coding* role carries neither the
  reading nor the writing — `assign_story_to_epic` is product's — so this is
  unambiguously work no single role in front of it can complete, and the main
  agent finishing it is the criterion rather than a favour.

  Distinct from 3316: there the role's limit had a written reason and routing
  round it was the wrong move. Here nothing says a coding agent must not have
  epics; it simply does not, and the work still has to happen.

  ## Asserted as the change, not the reply

  A tool that answers "done" without the story moving would pass an assertion on
  its own words. The epic membership is read back through the surface a person
  would use to check.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @script """
  return assign_story_to_epic({ story_id = ARGS.story, epic_id = ARGS.epic })
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent finishes work no role in front of it can" do
    scenario "a story needs an epic and the agent on the job has no epic tools" do
      given_ "a coding agent, a story and an epic it belongs in", context do
        reply = join_working_copy(context, "/tmp/spex-3327", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        epic = Fixtures.epic_fixture(scope, %{title: "Billing"})
        story = Fixtures.authored_story(scope, "Dunning emails go out")

        coding = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3327")
        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3327")

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:epic, epic)
         |> Map.put(:story, story)
         |> Map.put(:coding, coding)
         |> Map.put(:main, main)}
      end

      when_ "the main agent takes it on", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        script =
          @script
          |> String.replace("ARGS.story", "#{context.story.id}")
          |> String.replace("ARGS.epic", ~s("#{context.epic.id}"))

        {:reply, as_coding, _frame} =
          Fixtures.run_script(%{script: script, agent_id: context.coding.id}, frame)

        {:reply, as_main, _frame} =
          Fixtures.run_script(%{script: script, agent_id: context.main.id}, frame)

        {:ok,
         context
         |> Map.put(:as_coding, response_text(as_coding))
         |> Map.put(:as_main, response_text(as_main))}
      end

      then_ "the work is actually done", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, story, _frame} =
          GetStory.execute(%{story_id: to_string(context.story.id)}, frame)

        assert response_text(story) =~ "Billing",
               """
               The main agent could not finish work no role in front of it can.

               3313 says it can see past a role's tool list; this says it can
               act. A main agent that can only read turns every gap into a
               report — correct, safe, and nothing ever gets finished, which is
               the failure criterion 3321 on story 1057 already rejects for
               machinery faults.

               as main:
               #{context.as_main}

               story:
               #{response_text(story)}
               """

        {:ok, context}
      end

      then_ "and the role that could not do it still cannot", context do
        assert context.as_coding =~ ~r/not in scope|unknown|nil value/i,
               """
               The coding role can assign epics after all, so this scenario
               shows nothing about the main agent acting where a role cannot.

               The claim is comparative, the same as 3313's. If every role can
               do it, the criterion is about a capability everybody should have
               — a different and easier story, which this spex would be quietly
               passing.

               as coding:
               #{context.as_coding}
               """

        {:ok, context}
      end
    end
  end
end
