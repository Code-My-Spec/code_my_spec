defmodule CodeMySpec.Check.Warning.NoControlFlowInTests do
  @moduledoc """
  Credo check that forbids imperative control flow (`case`, `if`, `unless`,
  `cond`, `try`) inside test files (`_test.exs`) and BDD spec files
  (`_spex.exs`). See the `:check` explanation for rationale.
  """

  use Credo.Check,
    id: "CMS0003",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Imperative control flow (`case`, `if`, `cond`, `try/rescue`) is not allowed
      in test files (`_test.exs`) or BDD spec files (`_spex.exs`).

      Tests and scenarios should be declarative — straight-line setup +
      observation + assertion. Control flow in a test hides what's actually
      being asserted, makes failure output harder to read, and signals that
      the fixture isn't doing its job (the test is defending against shapes
      the setup should guarantee).

      Replace with:
      - Pattern-matching `=` for destructuring (`{:ok, value} = result`).
      - `assert match?(pattern, value)` for shape assertions.
      - Multi-clause helper functions (`defp handle(:ok, ...)` + `defp handle(:error, ...)`).
      - Tightening the fixture so the assertion can rely on a known shape.
      - For scenarios with conditional setup, split into separate tests/scenarios.

      Pattern matching in function heads and `with` clauses is fine —
      that's destructuring, not control flow. The forbidden constructs
      are imperative branching inside the test/scenario body.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{filename: filename} = source_file, params) do
    if test_or_spex?(filename) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp test_or_spex?(filename) do
    String.ends_with?(filename, "_test.exs") or String.ends_with?(filename, "_spex.exs")
  end

  defp walk({:case, meta, _} = ast, ctx) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "case"))}
  end

  defp walk({:if, meta, _} = ast, ctx) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "if"))}
  end

  defp walk({:unless, meta, _} = ast, ctx) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "unless"))}
  end

  defp walk({:cond, meta, _} = ast, ctx) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "cond"))}
  end

  defp walk({:try, meta, _} = ast, ctx) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "try"))}
  end

  defp walk(ast, ctx) do
    {ast, ctx}
  end

  defp issue_for(issue_meta, meta, construct) do
    format_issue(
      issue_meta,
      message:
        "Imperative `#{construct}` is not allowed in _test.exs / _spex.exs files. " <>
          "Use pattern matching, multi-clause helpers, or split into separate tests/scenarios.",
      trigger: construct,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
