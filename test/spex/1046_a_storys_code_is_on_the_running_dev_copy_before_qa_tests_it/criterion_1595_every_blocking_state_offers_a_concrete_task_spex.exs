defmodule CodeMySpecSpex.Story1046.Criterion1595Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.

  Harness's wedge check, requested after story 1003's reorder moved several
  edges in one sitting (`story_issues_resolved`, `problems_resolved`,
  `qa_complete`, `code_on_running_copy`, `deploy`). `problems_resolved` has
  since gone (28d72f8a): analyzer findings are the promote gate's job. A
  graph that long is a poor place to trust to instinct that every state along
  the chain still produces *something* to do — a single requirement that
  never resolves stalls every role waiting behind it, not just the one story
  that is actually broken (`one_unsatisfiable_requirement_wedges_the_whole_fleet`).

  One story per blocking state, in chain order, each asked for its next
  work and asserted to get back a concrete, actionable task naming the
  requirement actually blocking it — never "no work available".

  1. Specs red — `bdd_specs_passing` unsatisfied → `FixBddSpecs`.
  2. An accepted issue open — `story_issues_resolved` unsatisfied →
     `FixStoryIssues`.
  3. QA not yet run — `qa_complete` unsatisfied → `QaStory`.
  4. QA passed but not promoted — `story_promoted` unsatisfied →
     `PromoteWork`.
  5. Promoted — `deploy` unsatisfied → `Deploy`.

  A working copy's team works one story at a time (a31f1cd6: `set_active_story`
  fans the story out to the copy's coding and QA agents, and
  `StoryExecution.selected/3` reads it), so each `then_` below switches the
  team's story immediately before asking —
  the tool an agent would actually call, not a shortcut around it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project
  # `deploy` (state 5) has no node at all without this — d207ad38 removed it
  # from the default template; `Fixtures.enable_devops/1` is what puts it
  # back for a project that opted in.
  setup :devops_on

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Every blocking state along the story chain offers a concrete, actionable task",
    criterion: 1595 do
    scenario "one story per state, none left with nothing to do" do
      given_ "a project with the shared setup every story below builds on", context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        # `apply_up_to_analysis` leaves its own story with specs not yet
        # enforced — state 1, for free.
        #
        # A second, separate checkout designated main — otherwise
        # `WorkingCopies.main/1` answers `nil` and `code_on_running_copy`
        # reads vacuously true for every story ("no running copy
        # designated"), which would make states 4 and 5 indistinguishable.
        # Not a real git checkout: this test never calls `promote` or
        # `restart_app`, only asks the graph what it would offer, so nothing
        # here needs a working `justfile`.
        context = designate_a_separate_main_copy(context)
        # The team the story is set on: a copy without one cannot hold a story.
        Fixtures.running_agent(context.scope, role: "coding")
        Fixtures.running_agent(context.scope, role: "qa")
        {:ok, context}
      end

      then_ "the specs-red story is offered FixBddSpecs", context do
        text = ask_for_next_work(context, context.story.number)

        assert text =~ "FixBddSpecs",
               "a story whose specs have never gone green should be offered " <>
                 "the task that makes them green. Got: #{text}"

        refute no_work?(text), "the story read no actionable work. Got: #{text}"

        {:ok, context}
      end

      given_ "a second story, ready for QA, with one accepted issue open", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Story with an open issue",
            description: "As a user, I want issue-blocked work.",
            acceptance_criteria: ["Issue-blocked criterion"],
            priority: 2
          )

        context = ready_for_qa(context, story)

        {:ok, issue} =
          Issues.create_issue(context.scope, %{
            title: "Something QA found",
            description: "A defect this story's own QA pass raised.",
            severity: :high,
            story_id: story.id
          })

        {:ok, _accepted} = Issues.accept_issue(context.scope, issue)

        {:ok, Map.put(context, :issue_story, story)}
      end

      then_ "the issue-blocked story is offered FixStoryIssues", context do
        text = ask_for_next_work(context, context.issue_story.number)

        assert text =~ "FixStoryIssues",
               "a story with an open accepted issue should be offered the " <>
                 "task that resolves it. Got: #{text}"

        refute no_work?(text), "the story read no actionable work. Got: #{text}"

        {:ok, context}
      end

      given_ "a third story, clear of issues, ready for QA", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Story ready for QA",
            description: "As a user, I want QA-ready work.",
            acceptance_criteria: ["QA-ready criterion"],
            priority: 3
          )

        context = ready_for_qa(context, story)
        {:ok, Map.put(context, :qa_story, story)}
      end

      then_ "the QA-ready story is offered QaStory", context do
        text = ask_for_next_work(context, context.qa_story.number)

        assert text =~ "QaStory",
               "a story with clean specs and no issues should be " <>
                 "offered QA. Got: #{text}"

        refute no_work?(text), "the story read no actionable work. Got: #{text}"

        {:ok, context}
      end

      given_ "a fourth story that has passed QA but was never promoted", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Story passed QA, unpromoted",
            description: "As a user, I want post-QA work.",
            acceptance_criteria: ["Post-QA criterion"],
            priority: 4
          )

        context = ready_for_qa(context, story)
        {:ok, _attempt} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)

        {:ok, Map.put(context, :unpromoted_story, story)}
      end

      then_ "the unpromoted story is offered PromoteWork", context do
        text = ask_for_next_work(context, context.unpromoted_story.number)

        assert text =~ "PromoteWork",
               "a story that has passed QA but was never promoted should be " <>
                 "offered the task that promotes it. Got: #{text}"

        refute no_work?(text), "the story read no actionable work. Got: #{text}"

        {:ok, context}
      end

      given_ "a fifth story that has passed QA and was promoted", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Story promoted, not yet deployed",
            description: "As a user, I want post-promotion work.",
            acceptance_criteria: ["Post-promotion criterion"],
            priority: 5
          )

        context = ready_for_qa(context, story)
        {:ok, _attempt} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)

        story_struct = Stories.get_story(context.scope, story.id)

        {:ok, _story} =
          Stories.update_story(context.scope, story_struct, %{
            promoted_version: "v0.0.1-wedge-check"
          })

        {:ok, Map.put(context, :promoted_story, story)}
      end

      then_ "the promoted story is offered Deploy", context do
        # Not `get_next_requirement`: `deploy` is role `:main` and outside
        # `StoryExecution.@completion_names`, so a story satisfying every
        # completion requirement reads "complete for this working copy" —
        # correctly, for the coding/QA roles that tool serves — before
        # `deploy` is ever asked about. `list_requirements`, filtered to
        # this one story and requirement, is where the main role's own
        # discovery actually reads this — a concrete, named, unsatisfied
        # requirement, not an empty list.
        text = deploy_status(context, context.promoted_story.number)

        assert text =~ "[ ] **deploy**",
               "a promoted story ready for UAT should still show deploy as " <>
                 "open work, not satisfied and not absent. Got: #{text}"

        assert text =~ "deployed to UAT",
               "the row should name what deploy actually checks, so an agent " <>
                 "reading it knows what to do. Got: #{text}"

        {:ok, context}
      end
    end
  end

  # A checkout the test scope never becomes — so every story's own checkout
  # (the default copy `setup_active_project` already gave the scope) is
  # *not* the running copy, and `story_promoted` has an ancestry
  # question to answer rather than the "working on it directly" shortcut.
  #
  # No explicit "make main" click needed: `setup_active_project`'s own
  # default copy has never reported a root, so it never claimed the
  # designation, and this join — the first to report one — becomes main
  # automatically (`working_copies.ex:444`).
  defp designate_a_separate_main_copy(context) do
    running_root = CodeMySpec.TempFile.dir("spex-wedge-check-running")
    {_, 0} = Environments.cmd(context.environment, "mkdir", ["-p", running_root])

    _running = join_working_copy(context, running_root, "the checkout the app runs from")

    context
  end

  # Every story below the first shares the same "ready for QA" shape: linked
  # to the shared component, three-amigos sealed, its own BDD spec file
  # written, specs enforced and evaluated, clear of any issue. Rebuilt per
  # story rather than shared, because `story_issues_resolved` reads *this*
  # story's own state — one shared "ready" story mutated five times would make each
  # `then_` a statement about the last mutation, not about the state it
  # claims to test.
  defp ready_for_qa(context, story) do
    :ok =
      ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
        persona_id: context.persona_id
      )

    :ok = ProjectStateFixtures.apply_bdd_spec_for_story(context, story)

    enforce_specs_ready(context, story)
    _ = Fixtures.fresh_analysis_runs(context.scope)

    context
  end

  # The story page lost its Enforce toggle (e1174640): only a `promote` of
  # the story latches `specs_ready` now, which needs a merge this wedge
  # check does not build. Set directly, the same way
  # `FullSatisfactionFixtures.apply_specs_enforced/1` does for the same
  # reason.
  defp enforce_specs_ready(context, story) do
    story = Stories.get_story!(context.scope, story.id)
    {:ok, _} = Stories.set_specs_ready(context.scope, story, true)
    context
  end

  # The surface an agent actually calls before asking for work: one working
  # copy carries one active story at a time, so switching is how the copy's
  # own "which story am I on" answer changes — not a direct column write.
  # Stories are named by number at the tool boundary; only fixtures writing
  # domain rows directly (`Issues.create_issue`, `Stories.get_story`) take
  # the id.
  defp activate(context, story_number) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, _response, _frame} = SetActiveStory.execute(%{story_number: story_number}, frame)
    context
  end

  defp ask_for_next_work(context, story_number) do
    context = activate(context, story_number)
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
    response_text(response)
  end

  defp no_work?(text),
    do: text =~ "No requirement" or text =~ "no work" or text =~ "All requirements satisfied"

  # `list_requirements` reads `cached_all/1` straight, with no settle of its
  # own (`GetNextRequirement` settles on its way in; this tool is a read
  # model over whatever the last settle left). `ask_for_next_work/2` is what
  # actually processed this story's creation and every state change since —
  # called here for that side effect, its own answer unused.
  defp deploy_status(context, story_number) do
    _ = ask_for_next_work(context, story_number)

    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      ListRequirements.execute(
        %{entity_type: "story", entity_id: to_string(story_number), requirement_name: "deploy"},
        frame
      )

    response_text(response)
  end
end
