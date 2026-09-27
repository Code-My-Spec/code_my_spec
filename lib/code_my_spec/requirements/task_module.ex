defmodule CodeMySpec.Requirements.TaskModule do
  @moduledoc """
  The Ecto type for `RequirementDefinition.satisfied_by`: the agent task module
  that satisfies a requirement.

  Accepts any loaded module exporting `command/2` — the shape every agent task
  has — rather than checking membership of a list. `satisfied_by` used
  `Sessions.SessionType`, whose list names every task module. A schema's field
  type is a compile-time dependency, so that made every requirement definition
  recompile whenever anything any task module reaches changed — the whole app.
  This type names none of them. (Sessions are also on their way out; the
  definitions should not lean on them.)
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast(module) when is_atom(module),
    do: if(task_module?(module), do: {:ok, module}, else: :error)

  def cast(name) when is_binary(name) do
    name |> module_atom() |> cast()
  rescue
    ArgumentError -> :error
  end

  def cast(_other), do: :error

  @impl true
  def load(name) when is_binary(name), do: {:ok, module_atom(name)}

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(module) when is_atom(module), do: {:ok, module |> Atom.to_string() |> short()}
  def dump(_other), do: :error

  defp task_module?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :command, 2)

  defp module_atom("Elixir." <> _ = name), do: String.to_existing_atom(name)
  defp module_atom(name), do: String.to_existing_atom("Elixir." <> name)

  defp short("Elixir." <> name), do: name
  defp short(name), do: name
end
