defmodule CodeMySpec.Requirements.RequirementDefinition do
  @moduledoc """
  Immutable template defining what needs to be checked for a component.
  Maps to runtime Requirement instances which track satisfaction status.
  Enables artifact type categorization for UI grouping and clear separation
  between definition (what to check) and instance (whether satisfied).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Sessions.SessionType

  @type artifact_type ::
          :specification
          | :review
          | :code
          | :tests
          | :dependencies
          | :hierarchy

  @type scope :: :local | :children | :dependencies | :orchestrate | :pipeline

  @type validation_type :: :automatic | :manual
  @type execution_type :: :main_agent | :sub_agent

  @type check_type ::
          :file_exists
          | :file_valid
          | :path_exists
          | :field_present
          | :field_true
          | :no_problems
          | :tests_passing
          | :delegate

  @type node_scope :: :parent | :child | :self

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          satisfied_by: module() | nil,
          artifact_type: artifact_type(),
          check_type: check_type(),
          description: String.t(),
          threshold: float(),
          config: map(),
          prerequisites: [integer()],
          node_scope: node_scope(),
          scope: scope(),
          validation_type: validation_type(),
          execution_type: execution_type(),
          orchestrated_by: atom() | nil,
          render_command_always?: boolean(),
          subagent_role: atom() | nil
        }

  @artifact_types [
    :specification,
    :review,
    :code,
    :tests,
    :dependencies,
    :hierarchy
  ]

  @check_types [
    :file_exists,
    :file_valid,
    :path_exists,
    :field_present,
    :field_true,
    :no_problems,
    :tests_passing,
    :delegate
  ]

  @primary_key false
  embedded_schema do
    field :id, :integer
    field :name, :string
    field :satisfied_by, SessionType
    field :artifact_type, Ecto.Enum, values: @artifact_types
    field :check_type, Ecto.Enum, values: @check_types
    field :description, :string
    field :threshold, :float, default: 1.0
    field :config, :map, default: %{}
    field :prerequisites, {:array, :integer}, default: []
    field :node_scope, Ecto.Enum, values: [:parent, :child, :self], default: :self
    field :scope, Ecto.Enum, values: [:local, :children, :dependencies, :orchestrate, :pipeline], default: :local
    field :validation_type, Ecto.Enum, values: [:automatic, :manual], default: :automatic
    field :execution_type, Ecto.Enum, values: [:main_agent, :sub_agent], default: :main_agent
    field :orchestrated_by, Ecto.Enum,
      values: [:develop_context, :develop_live_context, :develop_controller],
      default: nil

    # When true, the requirement view should always render the
    # `satisfied_by` command, regardless of whether the requirement
    # is satisfied. Used for multi-step status reports (project_setup)
    # where the user wants to see in-progress detail at any time.
    # Defaults to false — most requirements show their command only
    # while unsatisfied (the prompt for the next agent step).
    field :render_command_always?, :boolean, default: false

    # The role atom identifying which sub-agent class owns this requirement
    # (e.g. `:qa`, `:coding`, `:spec_writer`). Set on sub_agent requirements
    # whose `dispatch/1` emits a structured `%{role: atom, prompt: String}`.
    # Used by the mapper to route dispatch: SendMessage to a live sub-agent
    # for this role, or Agent spawn if none is registered.
    # Nil means no role-based dispatch — use the default rendering path.
    field :subagent_role, Ecto.Enum,
      values: [:qa, :coding, :spec_writer],
      default: nil
  end

  @doc """
  Creates a new requirement definition from attributes map with validation.

  ## Process
  1. Extract required fields from attrs map
  2. Default threshold to 1.0 if not provided
  3. Validate threshold is between 0.0 and 1.0 if provided
  4. Default config to empty map if not provided
  5. Build and return RequirementDefinition struct

  ## Examples

      iex> new(%{
      ...>   name: :spec_file,
      ...>   checker: CodeMySpec.Requirements.FileExistenceChecker,
      ...>   satisfied_by: CodeMySpec.ComponentSpecSessions,
      ...>   artifact_type: :specification,
      ...>   description: "Component spec file exists"
      ...> })
      {:ok, %RequirementDefinition{}}

      iex> new(%{name: :spec_file, checker: InvalidChecker})
      {:error, %Ecto.Changeset{}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> case do
      %Ecto.Changeset{valid?: true} = changeset ->
        {:ok, Ecto.Changeset.apply_changes(changeset)}

      %Ecto.Changeset{valid?: false} = changeset ->
        {:error, changeset}
    end
  end

  @doc """
  Changeset for creating/validating a requirement definition.
  """
  def changeset(requirement_definition, attrs) do
    requirement_definition
    |> cast(attrs, [
      :id,
      :name,
      :satisfied_by,
      :artifact_type,
      :check_type,
      :description,
      :threshold,
      :config,
      :prerequisites,
      :node_scope,
      :scope,
      :validation_type,
      :execution_type,
      :orchestrated_by,
      :render_command_always?,
      :subagent_role
    ])
    |> validate_required([
      :name,
      :artifact_type,
      :description
    ])
    |> validate_name()
    |> validate_threshold()
  end

  defp validate_name(changeset) do
    case fetch_change(changeset, :name) do
      {:ok, name} when is_atom(name) ->
        # Convert atom to string for Ecto storage
        put_change(changeset, :name, Atom.to_string(name))

      {:ok, name} when is_binary(name) ->
        # Already a string, keep as-is
        changeset

      {:ok, _other} ->
        add_error(changeset, :name, "must be an atom or string")

      :error ->
        # No change to validate
        changeset
    end
  end

  defp validate_threshold(changeset) do
    changeset
    |> validate_number(:threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end

  @doc """
  Returns the name as an atom for pattern matching.
  """
  @spec name_atom(t()) :: atom()
  def name_atom(%__MODULE__{name: name}) when is_binary(name) do
    String.to_existing_atom(name)
  end

  def name_atom(%__MODULE__{name: name}) when is_atom(name), do: name
end
