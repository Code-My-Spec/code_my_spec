defmodule CodeMySpecSpex.RecordedAnalysis do
  @moduledoc """
  Recorded analyzer output for runs a spex starts through a tool.

  A spex's in-memory environment refuses to run an analyzer. Attach a recorded
  output per source and every run against that environment replays it:

      context = attach_recorded_analysis(context, spex: "test/fixtures/validation/spex_green.jsonl")

  Sources: `:compiler`, `:credo`, `:exunit`, `:spex`, `:sobelow`. Recordings live
  in `test/fixtures/validation/`.
  """

  use Boundary, top_level?: true, deps: [CodeMySpec, CodeMySpec.Environments]

  alias CodeMySpec.Environments
  alias CodeMySpec.Support.InMemoryEnvironment

  @doc """
  Returns `context` with the recordings on its scope's environment, and
  re-registers that environment so scopes rebuilt for the project carry them too.
  """
  @spec attach_recorded_analysis(map(), keyword(String.t())) :: map()
  def attach_recorded_analysis(%{scope: scope} = context, recordings) do
    env = Enum.reduce(recordings, scope.environment, &record/2)
    reregister(scope.active_project_id, env)

    context
    |> Map.replace(:environment, env)
    |> Map.put(:scope, %{scope | environment: env})
  end

  defp record({source, path}, env) do
    path = Path.expand(path)
    File.exists?(path) || raise ArgumentError, "no recorded analyzer output at #{path}"
    InMemoryEnvironment.record_output(env, to_string(source), path)
  end

  defp reregister(nil, _env), do: :ok

  defp reregister(project_id, env) do
    if Environments.lookup_registered(project_id) do
      Environments.unregister(project_id)
      Environments.register(project_id, env)
    end

    :ok
  end
end
