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

  alias CodeMySpec.Issues
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
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

    product = names(ctx.scope, :product)
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
