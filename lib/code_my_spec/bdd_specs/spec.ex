defmodule CodeMySpec.BddSpecs.Spec do
  @moduledoc """
  Struct representing a parsed BDD specification file.

  Contains metadata about the spec including its name, source file path,
  and parsed scenarios. Optionally links to story and criterion IDs derived
  from file naming conventions. Used as the primary data structure for spec
  analysis and rendering.
  """

  import Ecto.Changeset

  alias CodeMySpec.BddSpecs.Scenario

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          file_path: String.t() | nil,
          story_id: integer() | nil,
          criterion_id: integer() | nil,
          tags: list(atom()),
          scenarios: list(Scenario.t())
        }

  @derive {Jason.Encoder,
           only: [:name, :description, :file_path, :story_id, :criterion_id, :tags, :scenarios]}
  defstruct name: nil,
            description: nil,
            file_path: nil,
            story_id: nil,
            criterion_id: nil,
            tags: [],
            scenarios: []

  @doc """
  Builds a changeset for creating or validating a Spec struct with the given attributes.

  ## Examples

      iex> changeset(%Spec{}, %{name: "User auth", file_path: "/path/to/spec.ex"})
      #Ecto.Changeset<valid?: true, ...>

      iex> changeset(%Spec{}, %{name: "User auth"})
      #Ecto.Changeset<valid?: false, errors: [file_path: {"can't be blank", [validation: :required]}]>
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(spec, attrs) do
    types = %{
      name: :string,
      description: :string,
      file_path: :string,
      story_id: :integer,
      criterion_id: :integer,
      tags: {:array, :any},
      scenarios: {:array, :any}
    }

    {spec, types}
    |> cast(attrs, [:name, :description, :file_path, :story_id, :criterion_id, :tags])
    |> cast_scenarios(attrs)
    |> validate_required([:name, :file_path])
  end

  @doc """
  Constructs a new Spec struct from parsed attributes.

  Raises `Ecto.InvalidChangesetError` if the changeset is invalid.

  ## Examples

      iex> new(%{name: "User auth", file_path: "/path/to/spec.ex"})
      %Spec{name: "User auth", file_path: "/path/to/spec.ex", tags: [], scenarios: []}

      iex> new(%{name: "User auth"})
      ** (Ecto.InvalidChangesetError) ...
  """
  @spec new(map()) :: t()
  def new(attrs) do
    changeset = changeset(%__MODULE__{}, attrs)

    if changeset.valid? do
      # Apply the changeset and convert scenario changesets to structs
      data =
        changeset
        |> Ecto.Changeset.apply_action!(:insert)

      scenarios = apply_scenario_changes(get_change(changeset, :scenarios))

      %{data | scenarios: scenarios}
    else
      Ecto.Changeset.apply_action!(changeset, :insert)
    end
  end

  # Private helper to cast scenarios
  defp cast_scenarios(changeset, attrs) do
    scenarios =
      case Map.get(attrs, :scenarios) do
        nil ->
          []

        scenario_attrs when is_list(scenario_attrs) ->
          Enum.map(scenario_attrs, fn scenario_attr ->
            Scenario.changeset(%Scenario{}, scenario_attr)
          end)

        scenarios ->
          scenarios
      end

    put_change(changeset, :scenarios, scenarios)
  end

  defp apply_scenario_changes(nil), do: []

  defp apply_scenario_changes(scenario_changesets) when is_list(scenario_changesets) do
    Enum.map(scenario_changesets, &apply_scenario_change/1)
  end

  defp apply_scenario_changes(scenarios), do: scenarios

  defp apply_scenario_change(%Ecto.Changeset{} = cs), do: Ecto.Changeset.apply_action!(cs, :insert)
  defp apply_scenario_change(scenario), do: scenario
end
