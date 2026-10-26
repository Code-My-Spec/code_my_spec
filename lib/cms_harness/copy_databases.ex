defmodule CmsHarness.CopyDatabases do
  @moduledoc """
  A working copy's databases go when its checkout does.

  A copy's test partitions (`<app>_testh<digest>`, its `a`, `s` and sharded
  `_<n>` forms) and its app's clone (`<app>_dev_wc_<digest>`) are named after
  the root's digest, the one `ClientUtils.Harness.Onboarding.partition_name/1`
  derives. Nothing dropped them when a checkout was removed, and 99 piled up,
  5.3 GB of them, until the disk filled. Matched by digest, not app name, since
  a removed checkout's `mix.exs` cannot be read. Anything connected is left.
  """

  require Logger

  alias CmsHarness.AppInstance.Runner

  @doc "Drop the databases of the copy that lived at `root`. Answers the names dropped."
  @spec drop_for_root(String.t()) :: [String.t()]
  def drop_for_root(root) when is_binary(root) do
    digest = digest(root)

    runner = runner()

    "(_testh#{digest}(a|s)?(_[0-9]+)?|_dev_wc_#{digest})$"
    |> runner.idle_databases_matching()
    |> Enum.filter(fn database -> runner.drop_database(database) == :ok end)
    |> tap(&log(&1, root))
  end

  # `Runner` reaches the machine's Postgres; the suite swaps in one that finds
  # nothing, so a test that removes a checkout drops no real database.
  defp runner, do: Application.get_env(:code_my_spec, __MODULE__, [])[:runner] || Runner

  defp digest(root),
    do:
      root
      |> Path.expand()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

  defp log([], _root), do: :ok

  defp log(dropped, root),
    do: Logger.info("[CmsHarness] dropped #{root}'s databases: #{Enum.join(dropped, ", ")}")
end
