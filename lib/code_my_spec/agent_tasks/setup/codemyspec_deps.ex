defmodule CodeMySpec.AgentTasks.Setup.CodemyspecDeps do
  @moduledoc """
  Setup step: required CodeMySpec dependencies present in mix.exs.
  """

  alias CodeMySpec.Environments

  @required_deps [:credo, :client_utils, :sobelow, :sexy_spex, :boundary]

  def evaluate(scope, _task) do
    env = scope.environment

    case Environments.read_file(env, "mix.exs") do
      {:ok, content} ->
        missing = Enum.reject(@required_deps, &dep_present?(content, &1))

        if Enum.empty?(missing),
          do: {:ok, :valid},
          else: {:ok, :invalid, "Missing deps in `mix.exs`: #{Enum.map_join(missing, ", ", &":#{&1}")}"}

      _ ->
        {:ok, :invalid, "Cannot read `mix.exs`"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Add CodeMySpec Dependencies

    Add to `deps/0` in `mix.exs`:

    - `:credo` — static code analysis
    - `:client_utils` — CodeMySpec client utilities
    - `:sobelow` — security-focused static analysis
    - `:sexy_spex` — BDD specification testing
    - `:boundary` — module dependency enforcement

    Then: `mix deps.get`
    """}
  end

  defp dep_present?(content, dep_name) do
    atom_string = Atom.to_string(dep_name)
    Regex.match?(~r/\{:#{atom_string}[,\s]/, content)
  end
end
