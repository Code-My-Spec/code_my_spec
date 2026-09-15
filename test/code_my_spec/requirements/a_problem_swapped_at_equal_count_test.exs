defmodule CodeMySpec.Requirements.AProblemSwappedAtEqualCountTest do
  @moduledoc """
  A component's fingerprint has to move when its findings change, and hold
  still when they do not.

  Both halves are the claim, and each one is a different failure. The
  fingerprint used to hash `%{source => count}` — what the verdict reports —
  so correcting one credo violation and introducing another in the same module
  left it at 1 both times. `recompute_stale/3` skipped the component and it
  went on serving the corrected finding until something unrelated moved it: an
  agent is told to fix what it has already fixed, and told nothing about what
  it just broke.

  The other direction is what stopped `analysis_fresh` being an input at all
  (criterion 3448). Every write path in `ProblemRepository` is
  delete-then-insert, so ids and `updated_at` move on every analyzer run
  whether or not the code changed. A fingerprint keyed on the rows would
  restale every component with a problem each time the analyzer finished —
  1116 of 1347 requirements, measured.

  So the key is the findings: `{file_path, line, rule, message}`, aggregated
  per source.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Requirements.{Freshness, Preloader}

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp finding(scope, component, opts) do
    %Problem{
      project_id: scope.active_project_id,
      component_id: component.id,
      severity: :warning,
      source: "credo",
      source_type: :static_analysis,
      file_path: Keyword.get(opts, :file, "lib/app/thing.ex"),
      line: Keyword.get(opts, :line, 12),
      rule: Keyword.get(opts, :rule, "Credo.Check.Readability.ModuleDoc"),
      message: Keyword.get(opts, :message, "Modules should have a @moduledoc"),
      category: "readability"
    }
  end

  defp fingerprint(scope, component) do
    {:ok, ctx} = Preloader.load(scope)
    Freshness.component(ctx, Enum.find(ctx.components, &(&1.id == component.id)))
  end

  defp replace(scope, component, findings) do
    {:ok, _} = Problems.replace_problems_for_components(scope, [component.id], "credo", findings)
    :ok
  end

  test "a finding swapped for a different one at the same count moves the fingerprint", ctx do
    component = CodeMySpec.ComponentsFixtures.component_fixture(ctx.scope)

    :ok = replace(ctx.scope, component, [finding(ctx.scope, component, [])])
    before = fingerprint(ctx.scope, component)

    :ok =
      replace(ctx.scope, component, [
        finding(ctx.scope, component,
          line: 40,
          rule: "Credo.Check.Refactor.Nesting",
          message: "Function body is nested too deep"
        )
      ])

    refute fingerprint(ctx.scope, component) == before,
           """
           One finding was corrected and a different one appeared in its place,
           and the component's inputs hashed the same both times.

           The count is 1 either way, which is exactly why the count cannot be
           the key. A component whose fingerprint does not move is skipped by
           `recompute_stale/3`, so this component keeps serving the finding that
           was fixed and says nothing about the one that replaced it.
           """
  end

  test "the same findings found again do not move the fingerprint", ctx do
    component = CodeMySpec.ComponentsFixtures.component_fixture(ctx.scope)

    :ok = replace(ctx.scope, component, [finding(ctx.scope, component, [])])
    before = fingerprint(ctx.scope, component)

    # The analyzer ran again and found the same thing. New rows — `replace_*`
    # deletes and re-inserts — so every id and timestamp here is different.
    :ok = replace(ctx.scope, component, [finding(ctx.scope, component, [])])

    assert fingerprint(ctx.scope, component) == before,
           """
           An analyzer run that changed nothing restaled the component.

           This is the direction that costs whole recomputes rather than
           correctness: every write path replaces rows, so keying on ids or
           `updated_at` means each finished run invalidates every component that
           has a problem. That is the measurement criterion 3448 rests on.
           """
  end

  test "a finding that moves to another line moves the fingerprint", ctx do
    component = CodeMySpec.ComponentsFixtures.component_fixture(ctx.scope)

    :ok = replace(ctx.scope, component, [finding(ctx.scope, component, [])])
    before = fingerprint(ctx.scope, component)

    :ok = replace(ctx.scope, component, [finding(ctx.scope, component, line: 300)])

    refute fingerprint(ctx.scope, component) == before,
           "the same rule firing somewhere else is a different finding and has to read as one"
  end
end
