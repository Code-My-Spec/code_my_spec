defmodule CodeMySpec.Agents.Agent.TaskType do
  @moduledoc """
  The Ecto type for a task's `session_type`: the agent task module that does
  its work (`CodeMySpec.AgentTasks.*`).

  Names none of them, so the agent row does not recompile with every task
  module. Any loaded module exporting `command/2`, the shape every agent task
  has, is accepted; a short name ("TechnicalStrategy") or a full atom string is
  resolved against `CodeMySpec.AgentTasks`. Stored as the full atom string.
  """

  use Ecto.Type

  @namespace CodeMySpec.AgentTasks

  @type t :: module()

  @impl true
  def type, do: :string

  # Embedded as its dumped string and loaded back through `load/1`, so an old
  # row never goes through the strict `cast/1`.
  @impl true
  def embed_as(_format), do: :dump

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast(module) when is_atom(module),
    do: if(valid_type?(module), do: {:ok, module}, else: :error)

  def cast(name) when is_binary(name) do
    name |> resolve() |> cast()
  rescue
    ArgumentError -> :error
  end

  def cast(_other), do: :error

  # Tolerant: a task row whose module has since been deleted still loads, so
  # reading an old row never crashes. Strict validation stays on `cast/1`, so
  # new writes are still checked. `String.to_atom/1` is safe here: the set of
  # strings ever written is bounded, one per historical task module.
  @impl true
  def load(data) when is_binary(data), do: {:ok, String.to_atom(data)}
  def load(_data), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(module) when is_atom(module), do: {:ok, Atom.to_string(module)}
  def dump(_other), do: :error

  @doc "Whether `module` is a loaded agent task module."
  @spec valid_type?(term()) :: boolean()
  def valid_type?(module) when is_atom(module) and not is_nil(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :command, 2)

  def valid_type?(_other), do: false

  defp resolve("Elixir." <> _ = full), do: String.to_existing_atom(full)
  defp resolve(short), do: Module.concat(@namespace, short)
end
