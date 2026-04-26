defmodule CodeMySpec.BddSpecs.Scenario do
  @moduledoc """
  Struct representing a single scenario within a BDD spec.

  Contains the scenario name and organized collections of step descriptions
  grouped by type (given, when, then). Scenarios are the executable units
  within a spec that verify specific behaviors.
  """

  import Ecto.Changeset

  @type t :: %__MODULE__{
          name: String.t() | nil,
          given_steps: list(String.t()),
          when_steps: list(String.t()),
          then_steps: list(String.t()),
          line_number: pos_integer() | nil,
          tags: list(atom())
        }

  @derive {Jason.Encoder,
           only: [:name, :given_steps, :when_steps, :then_steps, :line_number, :tags]}
  defstruct name: nil,
            line_number: nil,
            given_steps: [],
            when_steps: [],
            then_steps: [],
            tags: []

  @doc """
  Create a new Scenario struct with the given attributes.

  ## Examples

      iex> Scenario.new(%{name: "User logs in"})
      %Scenario{name: "User logs in", given_steps: [], when_steps: [], then_steps: []}

      iex> Scenario.new(%{name: "Checkout", given_steps: ["cart has items"]})
      %Scenario{name: "Checkout", given_steps: ["cart has items"], when_steps: [], then_steps: []}
  """
  @spec new(map()) :: t()
  def new(attrs) do
    %__MODULE__{
      name: Map.get(attrs, :name),
      given_steps: Map.get(attrs, :given_steps, []),
      when_steps: Map.get(attrs, :when_steps, []),
      then_steps: Map.get(attrs, :then_steps, []),
      line_number: Map.get(attrs, :line_number),
      tags: Map.get(attrs, :tags, [])
    }
  end

  @doc """
  Build a changeset for a Scenario struct with validation.

  ## Examples

      iex> changeset(%Scenario{}, %{name: "Valid scenario"})
      #Ecto.Changeset<valid?: true, ...>

      iex> changeset(%Scenario{}, %{})
      #Ecto.Changeset<valid?: false, errors: [name: {"can't be blank", [validation: :required]}]>
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(scenario, attrs) do
    types = %{
      name: :string,
      given_steps: {:array, :string},
      when_steps: {:array, :string},
      then_steps: {:array, :string},
      line_number: :integer,
      tags: {:array, :any}
    }

    {scenario, types}
    |> cast(attrs, [:name, :given_steps, :when_steps, :then_steps, :line_number, :tags],
      empty_values: []
    )
    |> validate_name()
    |> validate_positive_line_number()
  end

  @doc """
  Add a given step description to the scenario's given_steps list.

  ## Examples

      iex> scenario = %Scenario{name: "test", given_steps: []}
      iex> add_given_step(scenario, "user is logged in")
      %Scenario{name: "test", given_steps: ["user is logged in"]}
  """
  @spec add_given_step(t(), String.t()) :: t()
  def add_given_step(%__MODULE__{given_steps: steps} = scenario, step) do
    %{scenario | given_steps: steps ++ [step]}
  end

  @doc """
  Add a when step description to the scenario's when_steps list.

  ## Examples

      iex> scenario = %Scenario{name: "test", when_steps: []}
      iex> add_when_step(scenario, "user clicks button")
      %Scenario{name: "test", when_steps: ["user clicks button"]}
  """
  @spec add_when_step(t(), String.t()) :: t()
  def add_when_step(%__MODULE__{when_steps: steps} = scenario, step) do
    %{scenario | when_steps: steps ++ [step]}
  end

  @doc """
  Add a then step description to the scenario's then_steps list.

  ## Examples

      iex> scenario = %Scenario{name: "test", then_steps: []}
      iex> add_then_step(scenario, "confirmation is shown")
      %Scenario{name: "test", then_steps: ["confirmation is shown"]}
  """
  @spec add_then_step(t(), String.t()) :: t()
  def add_then_step(%__MODULE__{then_steps: steps} = scenario, step) do
    %{scenario | then_steps: steps ++ [step]}
  end

  @doc """
  Count the total number of steps across all step types in the scenario.

  ## Examples

      iex> scenario = %Scenario{name: "test", given_steps: ["a"], when_steps: ["b"], then_steps: ["c", "d"]}
      iex> step_count(scenario)
      4
  """
  @spec step_count(t()) :: non_neg_integer()
  def step_count(%__MODULE__{given_steps: given, when_steps: when_s, then_steps: then_s}) do
    length(given) + length(when_s) + length(then_s)
  end

  @doc """
  Check if the scenario has any steps defined.

  ## Examples

      iex> scenario = %Scenario{name: "test", given_steps: [], when_steps: [], then_steps: []}
      iex> has_steps?(scenario)
      false

      iex> scenario = %Scenario{name: "test", given_steps: ["step"], when_steps: [], then_steps: []}
      iex> has_steps?(scenario)
      true
  """
  @spec has_steps?(t()) :: boolean()
  def has_steps?(%__MODULE__{given_steps: given, when_steps: when_s, then_steps: then_s}) do
    given != [] or when_s != [] or then_s != []
  end

  @doc """
  Retrieve all steps from the scenario as a single flat list, preserving order (given, when, then).

  ## Examples

      iex> scenario = %Scenario{name: "test", given_steps: ["a"], when_steps: ["b"], then_steps: ["c"]}
      iex> all_steps(scenario)
      ["a", "b", "c"]
  """
  @spec all_steps(t()) :: list(String.t())
  def all_steps(%__MODULE__{given_steps: given, when_steps: when_s, then_steps: then_s}) do
    given ++ when_s ++ then_s
  end

  # Private validation functions

  defp validate_name(changeset) do
    # Run length validation first, then check for nil separately
    changeset = validate_length(changeset, :name, min: 1, max: 500)

    # Only add "can't be blank" error if name is missing AND length validation didn't already add an error
    if get_change(changeset, :name) == nil and get_field(changeset, :name) == nil and
         changeset.errors[:name] == nil do
      add_error(changeset, :name, "can't be blank", validation: :required)
    else
      changeset
    end
  end

  defp validate_positive_line_number(changeset) do
    validate_number(changeset, :line_number, greater_than: 0)
  end
end
