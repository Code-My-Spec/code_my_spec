defmodule CodeMySpec.Environments.Environment do
  @moduledoc """
  Embedded schema representing an execution context.

  This struct encapsulates implementation-specific details for different execution
  environments (CLI with tmux, server-side, VS Code client).

  ## Fields

  - `type` - Environment type identifier (`:cli`, `:local`, `:vscode`)
  - `ref` - Implementation-specific reference data (map)
  - `cwd` - Current working directory for the environment
  - `metadata` - Optional context information

  ## Examples

      # CLI environment
      %Environment{
        type: :cli,
        cwd: "/path/to/project",
        ref: %{},
        metadata: %{session_id: 123}
      }

      # Local environment
      %Environment{
        type: :local,
        cwd: "/path/to/project",
        ref: %{working_dir: "/path/to/project"},
        metadata: %{}
      }

      # VSCode environment with connection ID
      %Environment{
        type: :vscode,
        cwd: "/path/to/workspace",
        ref: %{connection_id: "conn-abc123"},
        metadata: %{workspace: "/path/to/workspace"}
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          type: :cli | :local | :vscode | nil,
          ref: map(),
          cwd: String.t() | nil,
          metadata: map()
        }

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: [:cli, :local, :vscode]
    field :cwd, :string
    field :ref, :map, default: %{}
    field :metadata, :map, default: %{}
  end

  @doc """
  Creates a changeset for an Environment.
  """
  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [:type, :cwd, :ref, :metadata])
    |> validate_required([:type, :cwd])
  end

  @doc """
  Builds a new Environment struct with defaults.
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
