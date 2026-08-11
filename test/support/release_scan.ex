defmodule CodeMySpecTest.ReleaseScan do
  @moduledoc """
  Reading compiled beams for things a release will not have.

  Lives here rather than in `release_safety_test.exs` because it is scanning
  logic, and `NoControlFlowInTests` is right that a `case` in a test file is a
  test reacting to state instead of controlling it. This does not react to
  anything — it reads artefacts and reports, which is work, and work belongs in
  a module the rule does not police.
  """

  def modules_referencing_mix(path) do
    path
    |> String.to_charlist()
    |> :beam_lib.chunks([:atoms])
    |> offenders()
  end

  defp offenders({:ok, {mod, [atoms: atoms]}}), do: mix_reference(mod, atoms)
  defp offenders(_), do: []

  defp mix_reference(mod, atoms) do
    if shipped?(mod) and Enum.any?(atoms, fn {_, atom} -> atom == :"Elixir.Mix" end),
      do: [mod],
      else: []
  end

  # Only modules a release actually contains.
  #
  # This reads `ebin`, and under `MIX_ENV=test` that includes everything
  # compiled from `test/support` — helpers, fixtures, fake servers. None of it
  # is in a release: `elixirc_paths` adds those directories in the test
  # environment only. So a fixture calling `Mix.env()` to find a dotenv file was
  # reported as a module that "will raise UndefinedFunctionError the first time
  # the call is reached", in a build where the call is perfectly safe and the
  # release where it would not be does not contain the module.
  #
  # The check itself is right and worth keeping strict — it exists because a
  # `Mix.env()` in `lib/` crashed a packaged CLI. What was wrong is the
  # population it was asked about. Each beam records where it was compiled from,
  # so that is the question to ask rather than maintaining a list of test
  # modules to forgive.
  defp shipped?(mod) do
    case mod.module_info(:compile)[:source] do
      source when is_list(source) ->
        source
        |> List.to_string()
        |> Path.relative_to(File.cwd!())
        |> String.starts_with?("lib/")

      _ ->
        true
    end
  rescue
    # A module whose source cannot be read is judged, not excused: the whole
    # point is to fail toward reporting.
    _ -> true
  end
end
