defmodule CodeMySpecSpex.Story983.Criterion2022Spex do
  @moduledoc """
  Story 983 — Criterion 2022: adding a criterion to a shipped story puts it
  back in front of its team.

  Rule: a story revised after it shipped is not finished — the revision
  goes through the same gates the rest of the story did.

  A new criterion restarts the story's `specs_ready` chain the same way
  retiring one does (criterion 1902):
  `AcceptanceCriteriaRepository.create_criterion/3` calls
  `Stories.set_specs_ready(scope, story, false)` on insert, however
  settled the rest of the story already is. That alone reopens
  bdd_specs_exist — the new criterion has no spec file yet — so this
  criterion is really about what the team is shown next, not a new
  mechanism: `get_next_requirement` scoped to the story, before and after.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.ComponentGraphHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Promotion is queued: the queue's worker gates and lands it and tells the
  # agent, so the given waits for that before this criterion's own work starts.
  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A revision reopens a shipped story's gate in front of its team", criterion: 2022 do
    scenario "adding a criterion to a shipped story puts it back in front of its team" do
      given_ "a story whose implementation, QA and promotion all completed, its one criterion latched",
             context do
        context =
          context |> a_promotable_project() |> an_agent_on_the_copy() |> analyzers_are_current()

        context = ProjectStateFixtures.apply_persona(context)

        story =
          StoryHelpers.create_story(context.scope,
            title: "Promotable story",
            description: "As a user, I want this story's own code on the running copy.",
            acceptance_criteria: ["It works"]
          )

        module_name = "Story2022Surface"
        module_path = module_name |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)

        ComponentGraphHelpers.design!(context, module_name)

        :ok =
          Environments.write_file(
            context.environment,
            Content.impl_path(module_name),
            Content.impl_file(module_name)
          )

        :ok =
          Environments.write_file(context.environment, "test/#{module_path}_test.exs", """
          defmodule #{module_name}Test do
            use ExUnit.Case, async: true

            test "placeholder" do
              assert true
            end
          end
          """)

        ProjectStateFixtures.synced(context)
        story = StoryHelpers.set_component(context.scope, story.id, module_name)

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id,
            rule_statement: "Criterion 2022's surface works as the story says",
            happy_title: "The surface works",
            happy_body: "Given the surface exists\nWhen it is used\nThen it works",
            failure_title: "The surface rejects bad input",
            failure_body: "Given the surface exists\nWhen it is misused\nThen it refuses"
          )

        # bdd_specs_exist and QA happen last, against the story's final
        # shape — added after any Three Amigos artifact so this doesn't
        # itself leave the spec stale and the gate reopened.
        :ok = ProjectStateFixtures.apply_bdd_spec_for_story(context, story)
        :ok = sync_story_specs_to_local_copy(context, story)
        qa_ready_at = DateTime.utc_now()
        {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)

        refute set_active_story(context, story).isError
        commit_work(context, context.agent_root, "WORK.md", "work on story #{story.number}\n")
        context = analyzers_are_current(context)
        response = promote(context, story.number)
        assert what_the_agent_was_told(context) =~ "landed on main"
        refute response.isError, inspect(response)

        story = Stories.get_story(context.scope, story.id)

        assert story.specs_ready,
               "the story's specs_ready must be set before this scenario starts"

        {:ok, story} =
          Stories.set_qa_ready(context.scope, story, String.duplicate("a", 40), qa_ready_at)

        {:ok, Map.put(context, :story, story)}
      end

      then_ "the finished team waits for Main — nothing is offered to it", context do
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.agent_id}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        text = TaskResponseHelpers.response_text(response)

        assert String.downcase(text) =~ "waiting for main assignment",
               "expected the finished team to wait for Main, got: #{text}"

        {:ok, context}
      end

      when_ "a new criterion is added and Main assigns the revision to this team", context do
        response = add_criterion(context, context.story, "It also works on Tuesdays")
        refute response.isError, inspect(response)
        refute set_active_story(context, context.story).isError
        {:ok, context}
      end

      then_ "the story no longer reads as complete", context do
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.agent_id}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        text = TaskResponseHelpers.response_text(response)

        refute text =~ "This story is complete for this working copy.",
               "adding a criterion must reopen the story, got: #{text}"

        {:ok, Map.put(context, :next_requirement_text, text)}
      end

      then_ "its team is offered the work for the new criterion, not left idle", context do
        text = context.next_requirement_text

        assert text =~ "requirement_name=`bdd_specs_exist`",
               "expected the reopened story to offer bdd_specs_exist, got: #{text}"

        assert text =~ "entity_id=`#{context.story.number}`",
               "expected the offer to name this story, got: #{text}"

        {:ok, context}
      end
    end
  end
end
