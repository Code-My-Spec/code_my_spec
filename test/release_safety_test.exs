defmodule CodeMySpec.ReleaseSafetyTest do
  @moduledoc """
  Guards against patterns that compile fine but crash in prod releases.

  History: `Mix.env() == :test` shipped to prod once (commit c57933b0,
  2026-05-16) and crashed every new OAuth user landing on /app for days
  because Mix isn't bundled in compiled releases. This test prevents the
  same class of bug from shipping again.
  """

  use ExUnit.Case, async: true

  alias CodeMySpecTest.ReleaseScan

  @lib_root Path.expand("../lib", __DIR__)

  # Files where a `Mix.env` reference is intentional and safe — typically
  # string templates that emit instructions to a user, not runtime code.
  #
  # This list is a *lint* exemption, not a safety claim. What actually
  # guarantees the property is the compiled-artifact test below, which asks the
  # beam rather than the source and so cannot be fooled by where the call sits.
  @allowed_paths [
    "code_my_spec/agent_tasks/setup/compilers.ex"
  ]

  # Modules whose reference to Mix survives compilation and is still safe.
  # Kept separate from `@allowed_paths` because the reason is different: these
  # are about *when* the module runs, not where the call is written.
  @allowed_modules [
    # Mix tasks do not exist in a release; that is what makes them tasks.
    ~r/^Elixir\.Mix\.Tasks\./,
    # Asks whether Mix is loaded before touching it —
    # `Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0)` — which
    # is the correct way to answer "am I running under Mix" and is safe
    # precisely because it never assumes.
    ~r/^Elixir\.CodeMySpecLocalWeb\.Application$/
  ]

  test "no Mix.env() calls in lib/ (crashes in compiled releases)" do
    violations =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&scan_file/1)
      |> Enum.reject(fn {rel, _line, _src} -> rel in @allowed_paths end)
      |> Enum.reject(fn {rel, _line, _src} -> mix_task?(rel) end)

    assert violations == [],
           build_violation_message(violations)
  end

  # The authoritative check. The scan above reads source text, so it cannot
  # tell `Mix.env()` in a module attribute — resolved at compile time, never
  # present at runtime — from the same call in a function body, which is the
  # thing that crashed prod. It also only knows about `Mix.env`, so every other
  # Mix call passes it untouched.
  #
  # A module that calls into Mix has `Elixir.Mix` in its atom table. Asking the
  # artifact answers the real question: will anything in this release reach for
  # a module that is not there.
  test "no shipped module reaches for Mix at runtime" do
    offenders =
      :code_my_spec
      |> Application.app_dir("ebin")
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.flat_map(&ReleaseScan.modules_referencing_mix/1)
      |> Enum.reject(fn mod ->
        Enum.any?(@allowed_modules, &Regex.match?(&1, Atom.to_string(mod)))
      end)
      |> Enum.sort()

    assert offenders == [],
           """
           These compiled modules reference Mix, which is not bundled in a
           release. They will raise UndefinedFunctionError the first time the
           call is reached.

           A reference is fine when it is resolved at compile time (a module
           attribute) or guarded by `Code.ensure_loaded?(Mix)`. Neither applies
           here, or the module would not appear in the beam's atom table at all.

           #{Enum.map_join(offenders, "\n", &"  #{inspect(&1)}")}
           """
  end

  # The same exemption `@allowed_modules` already grants, applied where the
  # source scan can see it.
  #
  # These two checks were exempting on different grounds for one reason. The
  # compiled test says it outright — "Mix tasks do not exist in a release; that
  # is what makes them tasks" — and matches `Elixir.Mix.Tasks.*`; the source scan
  # had only a hand-listed path, so every mix task that used `Mix.env` had to be
  # added to a list by hand while the check that actually guarantees the property
  # already knew the rule. Two lists that must agree, with nothing linking them.
  #
  # `lib/mix/tasks/` is exactly the directory whose modules compile to
  # `Elixir.Mix.Tasks.*`, so this is the same predicate spelled for a path.
  defp mix_task?(rel), do: String.starts_with?(rel, "mix/tasks/")

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
