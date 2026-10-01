defmodule CodeMySpec.Requirements.AnAnalyzerLandingMovesNoComponentTest do
  @moduledoc """
  An analyzer's findings are not a component input.

  No component requirement reads problems (28d72f8a), so a component's
  fingerprint — and the graph's — must not move when an analyzer lands,
  whatever it found. It used to hash `{file_path, line, rule, message}` per
  source, which made every credo, compiler or exunit run that changed a finding
  recompute the components it touched, for verdicts that no longer exist.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Requirements.{Freshness, GraphFingerprint, Preloader}

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp finding(scope, component, opts) do
    %Problem{
      project_id: scope.active_project_id,
      component_id: component.id,
      severity: :warning,
      source: "credo",
      source_type: :static_analysis,
      file_path: "lib/app/thing.ex",
      line: Keyword.get(opts, :line, 12),
      rule: "Credo.Check.Readability.ModuleDoc",
      message: "Modules should have a @moduledoc",
      category: "readability"
    }
  end

  defp fingerprints(scope, component) do
    {:ok, ctx} = Preloader.load(scope)
    config = CodeMySpec.Configurations.get_or_create(scope)

    {Freshness.component(ctx, Enum.find(ctx.components, &(&1.id == component.id))),
     GraphFingerprint.compute(ctx, config)}
  end

  defp replace(scope, component, findings) do
    {:ok, _} = Problems.replace_problems_for_components(scope, [component.id], "credo", findings)
    :ok
  end

  test "a finding appearing, moving or clearing moves neither fingerprint", ctx do
    component = CodeMySpec.ComponentsFixtures.component_fixture(ctx.scope)
    before = fingerprints(ctx.scope, component)

    :ok = replace(ctx.scope, component, [finding(ctx.scope, component, [])])
    assert fingerprints(ctx.scope, component) == before

    :ok = replace(ctx.scope, component, [finding(ctx.scope, component, line: 300)])
    assert fingerprints(ctx.scope, component) == before

    :ok = replace(ctx.scope, component, [])
    assert fingerprints(ctx.scope, component) == before
  end
end
