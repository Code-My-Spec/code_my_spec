defmodule CodeMySpec.ExecutionContexts.ExecutionContext do
  @moduledoc """
  Embedded schema representing an execution context.

  This struct encapsulates implementation-specific details for different execution
  environments (CLI with tmux, server-side, container).

  ## Fields

  - `type` - ExecutionContext type identifier (`:cli`, `:local`, `:container`,
    `:memory`)
  - `ref` - Implementation-specific reference data (map)
  - `cwd` - Current working directory for the environment
  - `metadata` - Optional context information

  ## Examples

      # CLI environment
      %ExecutionContext{
        type: :cli,
        cwd: "/path/to/project",
        ref: %{},
        metadata: %{session_id: 123}
      }

      # Local environment
      %ExecutionContext{
        type: :local,
        cwd: "/path/to/project",
        ref: %{},
        metadata: %{}
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          type: :cli | :local | :container | :memory | :harness | nil,
          ref: map(),
          cwd: String.t() | nil,
          metadata: map()
        }

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: [:cli, :local]
    field :cwd, :string
    field :ref, :map, default: %{}
    field :metadata, :map, default: %{}
  end

  @doc """
  Creates a changeset for an ExecutionContext.
  """
  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [:type, :cwd, :ref, :metadata])
    |> validate_required([:type, :cwd])
  end

  @doc """
  Builds a new ExecutionContext struct with defaults.
  """
  def new(type, cwd, opts \\ []) do
    %__MODULE__{
      type: type,
      cwd: cwd,
      ref: Keyword.get(opts, :ref, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
