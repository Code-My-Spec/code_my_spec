defmodule CodeMySpec.BddSpecs.Step do
  @moduledoc """
  Struct representing a single Given/When/Then step within a scenario.

  Contains the step type, human-readable description, and source line number
  for traceability back to the original spec file.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          type: atom() | nil,
          description: String.t() | nil,
          line: integer() | nil
        }

  @valid_types [:given, :when, :then]

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: @valid_types
    field :description, :string
    field :line, :integer
  end

  @doc """
  Creates a new Step struct with the given type, description, and optional line number.

  ## Parameters

    * `type` - The step type (:given, :when, or :then)
    * `description` - Human-readable description of the step
    * `opts` - Keyword list of options. Supports `:line` for source line number

  ## Examples

      iex> Step.new(:given, "the user is logged in", line: 10)
      %Step{type: :given, description: "the user is logged in", line: 10}

      iex> Step.new(:when, "they click submit", [])
      %Step{type: :when, description: "they click submit", line: nil}
  """
  @spec new(atom(), String.t(), keyword()) :: t()
  def new(type, description, opts \\ []) do
    %__MODULE__{
      type: type,
      description: description,
      line: Keyword.get(opts, :line)
    }
  end

  @doc """
  Creates a new Given step with the given description and optional line number.

  ## Parameters

    * `description` - Human-readable description of the step
    * `opts` - Keyword list of options. Supports `:line` for source line number

  ## Examples

      iex> Step.given("the user is logged in", line: 10)
      %Step{type: :given, description: "the user is logged in", line: 10}
  """
  @spec given(String.t(), keyword()) :: t()
  def given(description, opts \\ []) do
    new(:given, description, opts)
  end

  @doc """
  Creates a new When step with the given description and optional line number.

  ## Parameters

    * `description` - Human-readable description of the step
    * `opts` - Keyword list of options. Supports `:line` for source line number

  ## Examples

      iex> Step.when_step("they click the submit button", line: 11)
      %Step{type: :when, description: "they click the submit button", line: 11}
  """
  @spec when_step(String.t(), keyword()) :: t()
  def when_step(description, opts \\ []) do
    new(:when, description, opts)
  end

  @doc """
  Creates a new Then step with the given description and optional line number.

  ## Parameters

    * `description` - Human-readable description of the step
    * `opts` - Keyword list of options. Supports `:line` for source line number

  ## Examples

      iex> Step.then_step("they should see a success message", line: 12)
      %Step{type: :then, description: "they should see a success message", line: 12}
  """
  @spec then_step(String.t(), keyword()) :: t()
  def then_step(description, opts \\ []) do
    new(:then, description, opts)
  end

  @doc """
  Converts a Step struct to a human-readable string format.

  ## Parameters

    * `step` - The Step struct to convert

  ## Examples

      iex> step = Step.given("the user is logged in", [])
      iex> Step.to_string(step)
      "Given the user is logged in"

      iex> step = Step.when_step("they click submit", [])
      iex> Step.to_string(step)
      "When they click submit"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{type: :given, description: description}) do
    "Given #{description}"
  end

  def to_string(%__MODULE__{type: :when, description: description}) do
    "When #{description}"
  end

  def to_string(%__MODULE__{type: :then, description: description}) do
    "Then #{description}"
  end

  @doc """
  Validates that a step type is one of the allowed values.

  ## Parameters

    * `type` - The step type to validate

  ## Examples

      iex> Step.type_valid?(:given)
      true

      iex> Step.type_valid?(:invalid)
      false

      iex> Step.type_valid?(nil)
      false
  """
  @spec type_valid?(atom()) :: boolean()
  def type_valid?(type) when type in @valid_types, do: true
  def type_valid?(_), do: false
end
