defmodule CodeMySpec.Requirements.AnotherRolesQueueDoesNotClampMineTest do
  @moduledoc """
  Story 1005, criterion 3491 — a coding agent gets its red spex while product's
  triage queue is still full.

  Watched on 2026-09-15: a coding agent on a checkout carrying five red spex
  criteria in its own role reported "the graph holds no work for its role", and
  `get_next_requirement` offered `TriageIssues` and nothing else. Triaging the
  queue by hand immediately opened `ComponentCode`, `FixBddSpecs`, `QaStory` and
  `FixIssues`; four fresh issues closed it again. Nothing about the coding work
  changed across either transition — the only variable was the depth of a queue
  belonging to product.

  ## Why it happened

  `issues_triaged` is product's, and `qa_setup` waits on it. `qa_setup` is the
  seam the graph doc calls "the whole-project gate that opens story-level work",
  and `project.qa_setup → story.component_linked` carries that into every story's
  chain. `compute_blocked_descendants/2` blocks a node when *any* transitive
  prerequisite is unsatisfied, whoever it belongs to, so one untriaged issue made
  every story's coding work unactionable for a role that could not clear it.

  The earlier repair — moving `qa_setup` off `issues_resolved` onto
  `issues_triaged` — met the same defect once before and fixed it by choosing a
  gate that was at least *satisfiable*. Satisfiable by somebody is not the same
  as satisfiable by the role being stopped, which is what this asserts.

  ## The premise has to carry real coding work

  A first version of this test brought the project fully green and then filed an
  issue. It passed against the unfixed code, because on a green project coding
  has nothing outstanding — so "coding sees nothing" was true either way and the
  assertion could not tell the two apart.

  `apply_up_to_analysis/1` is the chain minus the green analysis run, which is
  the step that satisfies `bdd_specs_passing`. That leaves a real, named piece of
  coding work on the board, which is the only state where this question has an
  answer worth reading.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)

    {:ok, _coding} =
      AgentsRepository.create_agent(ctx.scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: :coding,
        working_copy_id: ctx.scope.active_working_copy_id
      })

    {:ok, _} =
      Agents.assign_team(ctx.scope, ctx.scope.active_working_copy_id, ctx.story.id)

    :ok = GraphWatcher.settle(ctx.scope)
    ctx
  end

  defp names(scope, role) do
    scope |> Requirements.actionable_for_role(role) |> Enum.map(& &1.name) |> Enum.uniq()
  end

  defp file_an_issue(scope) do
    {:ok, _issue} =
      Issues.create_issue(scope, %{
        title: "something product has not looked at yet",
        description: "filed, untriaged, and none of coding's business",
        severity: :medium
      })

    :ok = GraphWatcher.settle(scope)
  end

  # An active story used to hide the project from every role, because
  # `actionable_for_role/2` is `story_execution/2` and a selected story scoped
  # the whole answer. Assigning a story is the first thing anyone does on a new
  # project, and doing it before the project chain finished stopped the fleet
  # dead: four roles idle over a ready `spex_boundary_ready`, `list_agent_work`
  # reporting "the graph holds no work for its role", and nothing naming the
  # story scope as the reason. Clearing the story started it within seconds.
  #
  # Only project-scope work is reached this way, and only for a role that asked.
  # Widening to the whole copy would offer *other stories*, which is what story
  # 561 forbids — a finished story answers "complete" rather than moving its own
  # copy onto the next one. Project requirements are in no story, so offering
  # them takes nothing from the active one.
  #
  # ## The premise has to be project work this role can actually do
  #
  # A first version asked `:main` against the bare fixture and asserted it saw
  # something. It saw nothing, and not because of any clamp: `apply_up_to_analysis/1`
  # leaves the project chain green, so main's only project requirement
  # (`work_dispatched`) was satisfied and there was nothing to hide. The test
  # went in red and stayed red, because the assertion it failed was its own
  # premise rather than the behaviour.
  #
  # Filing an issue is what makes the question answerable. `issues_triaged` is
  # product's, project-scope, and actionable the moment an untriaged medium+
  # issue exists — a real piece of work, outside the active story, belonging to
  # a role whose story queue is empty.
  test "a story with nothing for this role does not hide the project", ctx do
    assert names(ctx.scope, :product) == [],
           "the fixture settles the project, so product starts with nothing"

    :ok = file_an_issue(ctx.scope)

    product_work = names(ctx.scope, :product)

    assert "issues_triaged" in product_work,
           """
           `set_active_story` ran in setup and product has no work inside that
           story, so this is project-level work reached past a selected story.
           Before the fix the active story scoped the whole answer and product
           was told the graph held nothing for its role.
           """

    refute Enum.any?(product_work, &(&1 in ~w(component_linked three_amigos_complete))),
           "project work, not the active story's own chain"
  end

  test "coding keeps its own work while product's queue is untriaged", ctx do
    before = names(ctx.scope, :coding)

    assert before != [],
           """
           The premise is coding work outstanding, and there is none — so this
           test cannot tell a clamp from an empty board, which is exactly how its
           first version passed against the defect.

           coding before: #{inspect(before)}
           """

    file_an_issue(ctx.scope)

    after_filing = names(ctx.scope, :coding)

    assert after_filing != [],
           """
           Filing an issue emptied coding's queue.

           `issues_triaged` is product's. It gates `qa_setup`, which gates
           `story.component_linked`, which gates every story's chain — so one
           untriaged issue took away work coding could do and could not clear.
           That is the whole of criterion 3491.

           coding before: #{inspect(before)}
           coding after:  #{inspect(after_filing)}
           """

    assert Enum.sort(after_filing) == Enum.sort(before),
           """
           Filing an issue changed what coding is offered.

           Product's queue should order coding's work, not alter it. Anything
           that moves here means the clamp is still travelling, just less of it.

           before: #{inspect(Enum.sort(before))}
           after:  #{inspect(Enum.sort(after_filing))}
           """
  end

  test "triage is still product's, and is not handed to coding", ctx do
    file_an_issue(ctx.scope)

    product =
      ctx.scope
      |> Requirements.next_actionable_project()
      |> Enum.map(& &1.name)

    coding = names(ctx.scope, :coding)

    assert "issues_triaged" in product,
           """
           Filing an issue did not put triage in front of product, so the premise
           never arrived.

           product: #{inspect(product)}
           """

    refute "issues_triaged" in coding,
           """
           Product's triage is being offered to coding.

           The rule cuts both ways: coding must not be clamped by product's queue
           and must not be handed it either. A change that stopped clamping
           everywhere would pass the other test in this file and fail here.

           coding: #{inspect(coding)}
           """
  end
end
