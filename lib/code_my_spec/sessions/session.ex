defmodule CodeMySpec.Sessions.Session do
  @moduledoc """
  Embedded schema representing an agent task session.

  Serialized to/from JSON for filesystem storage — no database table.
  Uses Ecto embedded schema for casting and validation via changesets.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Sessions.SessionType

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: SessionType.t() | nil,
          priority: integer() | nil,
          status: :active | :complete | :failed | :cancelled | nil,
          component_module_name: String.t() | nil,
          external_conversation_id: String.t() | nil,
          state: map() | nil
        }

  @primary_key false
  embedded_schema do
    field :id, :string
    field :type, SessionType
    field :priority, :integer
    field :status, Ecto.Enum, values: [:active, :complete, :failed, :cancelled]
    field :component_module_name, :string
    field :external_conversation_id, :string
    field :state, :map
  end

  @doc """
  Build a changeset for creating or updating a session.

  Casts fields from attrs, validates type is required and maps to a valid
  agent task module, generates id if not present, and defaults status to :active.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :id,
      :type,
      :priority,
      :status,
      :component_module_name,
      :external_conversation_id,
      :state
    ])
    |> validate_required([:type])
    |> put_id_if_missing()
    |> put_default_status()
  end

  @doc """
  Serialize a Session struct to a JSON-encodable map.

  Converts struct to map and converts atom values (type, status) to strings.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = session) do
    %{
      id: session.id,
      type: type_to_string(session.type),
      priority: session.priority,
      status: atom_to_string(session.status),
      component_module_name: session.component_module_name,
      external_conversation_id: session.external_conversation_id,
      state: session.state
    }
  end

  @doc """
  Deserialize a JSON map into a Session struct.

  Casts the map through changeset/2 and applies the changeset to produce a struct.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def from_json(json_map) do
    changeset = changeset(%__MODULE__{}, json_map)

    if changeset.valid? do
      {:ok, apply_changes(changeset)}
    else
      {:error, changeset}
    end
  end

  # Private helpers

  defp put_id_if_missing(changeset) do
    case fetch_field(changeset, :id) do
      {_source, nil} -> put_change(changeset, :id, Ecto.UUID.generate())
      :error -> put_change(changeset, :id, Ecto.UUID.generate())
      _ -> changeset
    end
  end

  defp put_default_status(changeset) do
    case fetch_field(changeset, :status) do
      {_source, nil} -> put_change(changeset, :status, :active)
      :error -> put_change(changeset, :status, :active)
      _ -> changeset
    end
  end

  defp type_to_string(nil), do: nil

  defp type_to_string(type) when is_atom(type) do
    type
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
end
