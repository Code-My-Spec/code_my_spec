defmodule CodeMySpec.ReleaseSafetyTest do
  @moduledoc """
  Guards against patterns that compile fine but crash in prod releases.

  History: `Mix.env() == :test` shipped to prod once (commit c57933b0,
  2026-05-16) and crashed every new OAuth user landing on /app for days
  because Mix isn't bundled in compiled releases. This test prevents the
  same class of bug from shipping again.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../lib", __DIR__)

  # Files where a `Mix.env` reference is intentional and safe — typically
  # string templates that emit instructions to a user, not runtime code.
  @allowed_paths [
    "code_my_spec/agent_tasks/setup/compilers.ex"
  ]

  test "no Mix.env() calls in lib/ (crashes in compiled releases)" do
    violations =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&scan_file/1)
      |> Enum.reject(fn {rel, _line, _src} -> rel in @allowed_paths end)

    assert violations == [],
           build_violation_message(violations)
  end

  defp scan_file(path) do
    rel = Path.relative_to(path, @lib_root)

    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Stream.filter(fn {line, _no} -> line =~ ~r/\bMix\.env\b/ end)
    |> Enum.map(fn {line, no} -> {rel, no, String.trim_trailing(line)} end)
  end

  defp build_violation_message(violations) do
    """
    Found Mix.env/0 calls in lib/. Mix isn't bundled in prod releases and
    these will crash at runtime with UndefinedFunctionError.

    Either:
      - Remove the call entirely (preferred — defense-in-depth, dev-only
        special cases, and test bypasses belong in tests, not production
        components)
      - If env-aware runtime behavior is genuinely required, use
        Application.compile_env(:code_my_spec, :env) with `config :code_my_spec,
        :env, Mix.env()` set in config.exs
      - If the reference is in a heredoc/template emitting code to the
        user (not runtime), add the path to @allowed_paths in
        test/release_safety_test.exs

    Violations:
    #{Enum.map_join(violations, "\n", fn {rel, line, src} -> "  #{rel}:#{line}  #{src}" end)}
    """
  end
end
