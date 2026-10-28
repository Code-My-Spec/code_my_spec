defmodule CodeMySpecTest.ReleaseScan do
  @moduledoc """
  Reading compiled beams for things a release will not have.

  Lives here rather than in `release_safety_test.exs` because it is scanning
  logic, and `NoControlFlowInTests` is right that a `case` in a test file is a
  test reacting to state instead of controlling it. This does not react to
  anything — it reads artefacts and reports, which is work, and work belongs in
  a module the rule does not police.
  """

  @doc "Every shipped module among `paths` that references Mix, read in parallel."
  def modules_referencing_mix_in(paths) do
    paths
    |> Task.async_stream(&modules_referencing_mix/1, ordered: false, timeout: :infinity)
    |> Enum.flat_map(fn {:ok, mods} -> mods end)
  end

  def modules_referencing_mix(path) do
    path
    |> String.to_charlist()
    |> :beam_lib.chunks([:atoms, :compile_info])
    |> offenders()
  end

  # The atom table first, and the source from the beam's own compile_info:
  # asking `mod.module_info/1` loaded every one of ~1,700 modules to read one
  # path, slow enough to pass ExUnit's 60s on a loaded promotion gate.
  defp offenders({:ok, {mod, [atoms: atoms, compile_info: info]}}) do
    if Enum.any?(atoms, fn {_, atom} -> atom == :"Elixir.Mix" end) and shipped?(info[:source]),
      do: [mod],
      else: []
  end

  defp offenders(_), do: []

  # Only modules a release actually contains.
  #
  # This reads `ebin`, and under `MIX_ENV=test` that includes everything
  # compiled from `test/support` — helpers, fixtures, fake servers. None of it
  # is in a release: `elixirc_paths` adds those directories in the test
  # environment only. Each beam records where it was compiled from, so that is
  # the question to ask rather than maintaining a list of test modules to
  # forgive. A beam with no recorded source is judged, not excused: the point
  # is to fail toward reporting.
  defp shipped?(source) when is_list(source) do
    source
    |> List.to_string()
    |> Path.relative_to(File.cwd!())
    |> String.starts_with?("lib/")
  end

  defp shipped?(_unrecorded), do: true
end
