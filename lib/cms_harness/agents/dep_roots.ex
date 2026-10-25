defmodule CmsHarness.Agents.DepRoots do
  @moduledoc """
  The source directories of a checkout's path dependencies, as Mix resolves
  them: code the project builds and runs, kept outside the checkout.

  The read tool allows these, read-only, so an agent can inspect what its own
  build depends on (`Tools.Read`). A sibling repository that is not a
  dependency stays refused.

  Asked of `mix deps` only when a read has been refused, since it takes
  seconds, and kept per checkout until its `mix.exs` changes.
  """

  @doc "Path dependency roots for `working_copy`; `[]` for a checkout without `mix.exs`."
  @spec for(String.t()) :: [String.t()]
  def for(working_copy) do
    mix_exs = Path.join(working_copy, "mix.exs")

    case File.stat(mix_exs, time: :posix) do
      {:ok, %{mtime: mtime}} -> cached({working_copy, mtime}, fn -> resolve(working_copy) end)
      {:error, _} -> []
    end
  end

  @doc """
  The absolute paths in `mix deps` output. Hex and git dependencies name a
  package or a URL there, never an absolute path, and git ones live under
  the checkout's own `deps/` anyway.
  """
  @spec parse(String.t()) :: [String.t()]
  def parse(output) do
    ~r/^\* \S+(?: \S+)? \((\/[^)]+)\)/m
    |> Regex.scan(output, capture: :all_but_first)
    |> List.flatten()
  end

  defp resolve(working_copy) do
    case System.cmd("mix", ["deps"], cd: working_copy, stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      {_output, _status} -> []
    end
  end

  defp cached(key, fun) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil ->
        roots = fun.()
        :persistent_term.put({__MODULE__, key}, roots)
        roots

      roots ->
        roots
    end
  end
end
