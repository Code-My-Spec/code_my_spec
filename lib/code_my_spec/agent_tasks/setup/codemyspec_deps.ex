defmodule CodeMySpec.AgentTasks.Setup.CodemyspecDeps do
  @moduledoc """
  Setup step: required CodeMySpec dependencies present in mix.exs.
  """

  @required_deps [:credo, :client_utils, :sobelow, :sexy_spex, :boundary]

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()
    mix_exs = Path.join(dir, "mix.exs")

    case File.read(mix_exs) do
      {:ok, content} ->
        missing = Enum.reject(@required_deps, &dep_present?(content, &1))

        if Enum.empty?(missing),
          do: {:ok, :valid},
          else: {:ok, :invalid, "Missing deps in `#{mix_exs}`: #{Enum.map_join(missing, ", ", &":#{&1}")}"}

      _ ->
        {:ok, :invalid, "Cannot read `#{mix_exs}`"}
    end
  end

  def command(scope, _task) do
    dir = scope.cwd || File.cwd!()

    {:ok, """
    # Add CodeMySpec Dependencies

    Add to `deps/0` in `#{Path.join(dir, "mix.exs")}`:

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
