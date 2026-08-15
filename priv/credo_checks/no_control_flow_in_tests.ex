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
      Imperative control flow (`case`, `if`, `unless`, `cond`, `try/rescue`)
      is not allowed in test files (`_test.exs`) or BDD spec files
      (`_spex.exs`).

      A test must be fully deterministic: you own the setup, so you know
      *exactly* what every value and shape will be, and you assert that
      exact thing. A branch in a test is a contradiction — it means the
      test is reacting to state it claims to control. Either the setup
      isn't pinned down (fix the fixture so the outcome is known) or the
      branch is dead weight guarding against a shape that cannot occur
      (delete it and assert directly).

      `if`/`case` to "handle either outcome" is the tell: if both outcomes
      are genuinely possible, the test is non-deterministic and can pass
      for the wrong reason. Decide which outcome you require, make the
      setup guarantee it, and assert it unconditionally — the test should
      *fail* when you don't get it, not quietly take the other branch.

      Replace with:
      - Pattern-matching `=` for destructuring (`{:ok, value} = result`) —
        it fails loudly when the shape is wrong, which is the point.
      - `assert match?(pattern, value)` for shape assertions.
      - Multi-clause helper functions for genuinely distinct cases — each
        becomes its own named test, not a branch.
      - A tighter fixture: pin the state so only one outcome is possible.
      - For cleanup or environment plumbing (`try/after`, resetting app
        env), use `on_exit` or move it into a setup/support helper — the
        test body asserts, it doesn't manage resources.

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
          "A branch means the test is reacting to state it should control — make the " <>
          "setup deterministic and assert the exact expected outcome instead.",
      trigger: construct,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
