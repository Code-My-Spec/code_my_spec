defmodule CodeMySpec.Requirements.Requirement do
  @moduledoc """
  Embedded schema representing a component requirement instance with its satisfaction status.
  Created from RequirementDefinition templates and tracks runtime satisfaction state.
  Supports both boolean pass/fail via satisfied field and incremental quality scoring (0.0 to 1.0)
  for nuanced requirement assessment.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.CheckerType
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Sessions.SessionType
  alias CodeMySpec.Stories.Story

  @type artifact_type ::
          :specification
          | :review
          | :code
          | :tests
          | :dependencies
          | :hierarchy

  @type scope :: :local | :children | :dependencies | :orchestrate

  @type requirement_attrs :: %{
          name: String.t(),
          artifact_type: artifact_type(),
          description: String.t(),
          checker_module: String.t(),
          satisfied_by: String.t() | nil,
          scope: scope(),
          satisfied: boolean(),
          score: float() | nil,
          checked_at: DateTime.t(),
          details: map()
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          artifact_type: artifact_type() | nil,
          description: String.t() | nil,
          checker_module: CheckerType.t() | nil,
          satisfied_by: SessionType.t() | nil,
          scope: scope(),
          satisfied: boolean(),
          score: float() | nil,
          checked_at: DateTime.t() | nil,
          details: map(),
          component_id: Ecto.UUID.t() | nil,
          component: Component.t() | Ecto.Association.NotLoaded.t(),
          story_id: integer() | nil,
          story: Story.t() | Ecto.Association.NotLoaded.t(),
          project_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @artifact_types [:specification, :review, :code, :tests, :dependencies, :hierarchy]

  schema "requirements" do
    field :name, :string
    field :artifact_type, Ecto.Enum, values: @artifact_types
    field :description, :string
    field :checker_module, CheckerType
    field :satisfied_by, SessionType
    field :scope, Ecto.Enum, values: [:local, :children, :dependencies, :orchestrate], default: :local
    field :satisfied, :boolean, default: false
    field :score, :float
    field :checked_at, :utc_datetime
    field :details, :map, default: %{}
    belongs_to :component, Component, type: :binary_id
    belongs_to :story, Story
    belongs_to :project, Project, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a passing requirement result with perfect score.

  ## Examples

      iex> ok()
      %Requirement{satisfied: true, score: 1.0, details: %{}}

  """
  @spec ok() :: t()
  def ok do
    %__MODULE__{
      satisfied: true,
      score: 1.0,
      details: %{}
    }
  end

  @doc """
  Creates a failing requirement result with the given errors.

  ## Examples

      iex> error(["File not found"])
      %Requirement{satisfied: false, score: 0.0, details: %{errors: ["File not found"]}}

  """
  @spec error([String.t()]) :: t()
  def error(errors) when is_list(errors) do
    %__MODULE__{
      satisfied: false,
      score: 0.0,
      details: %{errors: errors}
    }
  end

  @doc """
  Creates a requirement result with a custom score and errors for partial satisfaction scenarios.

  Score must be between 0.0 and 1.0. Satisfied is determined by comparing score to threshold (>= 0.7).

  ## Examples

      iex> partial(0.8, [])
      %Requirement{satisfied: true, score: 0.8, details: %{errors: []}}

      iex> partial(0.5, ["Some warnings"])
      %Requirement{satisfied: false, score: 0.5, details: %{errors: ["Some warnings"]}}

  """
  @spec partial(float(), [String.t()]) :: t()
  def partial(score, errors) when is_float(score) and is_list(errors) do
    threshold = 0.7

    cond do
      score < 0.0 ->
        raise ArgumentError, "score must be >= 0.0, got: #{score}"

      score > 1.0 ->
        raise ArgumentError, "score must be <= 1.0, got: #{score}"

      true ->
        %__MODULE__{
          satisfied: score >= threshold,
          score: score,
          details: %{errors: errors}
        }
    end
  end

  @doc """
  Creates a requirement instance from a RequirementDefinition template with computed satisfaction status.

  Calls the checker module's check/3 function and uses the threshold from the requirement definition
  to determine if the requirement is satisfied.

  ## Examples

      iex> from_spec(requirement_definition, component)
      %Requirement{satisfied: true, score: 1.0, ...}

  """
  @spec from_spec(RequirementDefinition.t(), Component.t() | Story.t() | Project.t()) :: t()
  def from_spec(%RequirementDefinition{} = requirement_definition, entity) do
    checker = requirement_definition.checker
    check_result = checker.check(requirement_definition, entity, [])

    # Extract score from check result or default based on satisfied
    score =
      case Map.get(check_result, :score) do
        nil -> if check_result.satisfied, do: 1.0, else: 0.0
        score -> score
      end

    # Determine satisfied by comparing score to threshold
    threshold = requirement_definition.threshold
    satisfied = score >= threshold

    base = %__MODULE__{
      name: requirement_definition.name,
      artifact_type: requirement_definition.artifact_type,
      description: requirement_definition.description,
      checker_module: requirement_definition.checker,
      satisfied_by: requirement_definition.satisfied_by,
      scope: requirement_definition.scope,
      satisfied: satisfied,
      score: score,
      checked_at: DateTime.utc_now(),
      details: check_result.details
    }

    case entity do
      %Component{id: id} -> %{base | component_id: id}
      %Story{id: id} -> %{base | story_id: id}
      %Project{id: id} -> %{base | project_id: id}
    end
  end

  @doc """
  Creates a changeset for inserting or updating a requirement.

  Validates all required fields and score range.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(requirement \\ %__MODULE__{}, attrs) do
    requirement
    |> cast(attrs, [
      :name,
      :artifact_type,
      :description,
      :checker_module,
      :satisfied_by,
      :scope,
      :satisfied,
      :score,
      :checked_at,
      :details,
      :component_id,
      :story_id,
      :project_id
    ])
    |> validate_required([:name, :artifact_type, :description, :checker_module, :satisfied])
    |> validate_score()
  end

  @doc """
  Creates a changeset for updating requirement satisfaction status and score only.

  Does not allow modification of name, artifact_type, description, or checker fields.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(requirement, attrs) do
    requirement
    |> cast(attrs, [:satisfied, :score, :checked_at, :details])
    |> validate_required([:satisfied])
    |> validate_score()
  end

  @doc """
  Returns the requirement name as an atom for pattern matching against Registry definitions.

  ## Examples

      iex> name_atom(%Requirement{name: "spec_file"})
      :spec_file

  """
  @spec name_atom(t()) :: atom()
  def name_atom(%__MODULE__{name: name}) when is_binary(name) do
    String.to_existing_atom(name)
  end

  @doc """
  Returns the checker module for requirement validation.

  ## Examples

      iex> checker_module(%Requirement{checker_module: "CodeMySpec.Requirements.FileExistenceChecker"})
      CodeMySpec.Requirements.FileExistenceChecker

  """
  @spec checker_module(t()) :: module()
  def checker_module(%__MODULE__{checker_module: module}) when is_atom(module) do
    module
  end

  def checker_module(%__MODULE__{checker_module: module_string}) when is_binary(module_string) do
    String.to_existing_atom("Elixir." <> module_string)
  end

  # Private functions

  defp validate_score(changeset) do
    case get_change(changeset, :score) do
      nil ->
        changeset

      score ->
        if score < 0.0 or score > 1.0 do
          add_error(changeset, :score, "must be between 0.0 and 1.0")
        else
          changeset
        end
    end
  end
end
