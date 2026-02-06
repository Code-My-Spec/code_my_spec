defmodule CodeMySpec.Sessions.Command do
  @moduledoc """
  Embedded schema representing a command to be executed during a session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder

  @type t :: %__MODULE__{
          id: binary() | nil,
          module: String.t() | nil,
          execution_strategy: atom() | nil,
          command: String.t() | nil,
          metadata: map() | nil,
          pipe: String.t() | nil,
          timestamp: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  embedded_schema do
    field :module, :string
    field :execution_strategy, Ecto.Enum, values: [:task, :async, :sync], default: :sync
    field :command, :string
    field :pipe, :string
    field :metadata, :map, default: %{}
    field :timestamp, :utc_datetime_usec
  end

  def changeset(command \\ %__MODULE__{}, attrs) do
    command
    |> cast(attrs, [:module, :execution_strategy, :command, :pipe, :metadata])
    |> validate_required([:module, :command])
    |> put_timestamp()
  end

  defp put_timestamp(changeset) do
    case get_field(changeset, :timestamp) do
      nil -> put_change(changeset, :timestamp, DateTime.utc_now())
      _ -> changeset
    end
  end

  @doc """
  Creates a new command.

  ## Options
  - `:metadata` - Map of metadata (e.g., prompt, options, child_session_ids)

  ## Examples

      # Claude SDK command
      Command.new(MyModule, "claude",
        metadata: %{prompt: "Generate...", options: %{model: "claude-3-opus"}},
      )

      # Spawn sessions command
      Command.new(MyModule, "spawn_sessions",
        metadata: %{child_session_ids: [1, 2, 3]}
      )
  """

  def new(module, command, opts \\ []) do
    %__MODULE__{
      module: module,
      command: command,
      execution_strategy: Keyword.get(opts, :execution_strategy, :sync),
      metadata: Keyword.get(opts, :metadata, %{}),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Check if a command requires terminal visualization.

  Currently only "claude" commands run in the terminal. This can be extended
  as new terminal-bound command types are added.

  ## Examples

      iex> Command.runs_in_terminal?(%Command{command: "claude"})
      true

      iex> Command.runs_in_terminal?(%Command{command: "spawn_sessions"})
      false
  """
  @spec runs_in_terminal?(t()) :: boolean()
  def runs_in_terminal?(%__MODULE__{command: "claude"}), do: true
  def runs_in_terminal?(_), do: false
end
