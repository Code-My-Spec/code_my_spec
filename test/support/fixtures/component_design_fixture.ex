defmodule CodeMySpec.ComponentDesignFixture do
  @moduledoc """
  Embedded schema representing a Component Design specification.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :purpose, :string
    field :public_api, :string
    field :execution_flow, :string
    field :other_sections, :map
  end

  def changeset(component_design, attrs, _scope \\ nil) do
    component_design
    |> cast(attrs, [:purpose, :public_api, :execution_flow, :other_sections])
    |> validate_required(required_fields())
  end

  def required_fields, do: [:purpose, :public_api, :execution_flow]

  def field_descriptions do
    %{
      purpose: "Component's purpose",
      public_api: "Public API specification"
    }
  end
end
