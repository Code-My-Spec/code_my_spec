defmodule CodeMySpec.Components.Component do
  @moduledoc """
  Ecto schema for Component entities representing Elixir code files within project architecture.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  # Namespace UUID for components (randomly generated, should remain constant)
  @component_namespace_uuid "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Components.ComponentStatus
  alias CodeMySpec.Components.Dependency
  alias CodeMySpec.Components.SimilarComponent
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories.Story

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          type: String.t(),
          module_name: String.t(),
          description: String.t() | nil,
          synced_at: DateTime.t() | nil,
          files_changed_at: DateTime.t() | nil,
          last_analyzed_at: map(),
          account_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          parent_component_id: Ecto.UUID.t() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t(),
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          parent_component: t() | Ecto.Association.NotLoaded.t() | nil,
          child_components: [t()] | Ecto.Association.NotLoaded.t(),
          outgoing_dependencies: [Dependency.t()] | Ecto.Association.NotLoaded.t(),
          incoming_dependencies: [Dependency.t()] | Ecto.Association.NotLoaded.t(),
          dependencies: [t()] | Ecto.Association.NotLoaded.t(),
          dependents: [t()] | Ecto.Association.NotLoaded.t(),
          outgoing_similar_components: [SimilarComponent.t()] | Ecto.Association.NotLoaded.t(),
          incoming_similar_components: [SimilarComponent.t()] | Ecto.Association.NotLoaded.t(),
          similar_components: [t()] | Ecto.Association.NotLoaded.t(),
          referenced_by_components: [t()] | Ecto.Association.NotLoaded.t(),
          stories: [CodeMySpec.Stories.Story.t()] | Ecto.Association.NotLoaded.t(),
          requirements: [Requirement.t()] | Ecto.Association.NotLoaded.t(),
          component_status: ComponentStatus.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "components" do
    field :name, :string

    field :type, :string
    field :module_name, :string
    field :description, :string
    field :synced_at, :utc_datetime
    field :files_changed_at, :utc_datetime
    field :last_analyzed_at, :map, default: %{}

    belongs_to :account, Account, type: :binary_id
    belongs_to :project, Project, type: :binary_id
    belongs_to :parent_component, __MODULE__, type: :binary_id

    has_many :child_components, __MODULE__, foreign_key: :parent_component_id
    has_many :outgoing_dependencies, Dependency, foreign_key: :source_component_id
    has_many :incoming_dependencies, Dependency, foreign_key: :target_component_id

    has_many :dependencies, through: [:outgoing_dependencies, :target_component]
    has_many :dependents, through: [:incoming_dependencies, :source_component]

    has_many :outgoing_similar_components, SimilarComponent, foreign_key: :component_id
    has_many :incoming_similar_components, SimilarComponent, foreign_key: :similar_component_id
    has_many :similar_components, through: [:outgoing_similar_components, :similar_component]
    has_many :referenced_by_components, through: [:incoming_similar_components, :component]

    has_many :problems, Problem
    has_many :stories, Story
    has_many :requirements, Requirement

    embeds_one :component_status, ComponentStatus

    timestamps(type: :utc_datetime)
  end

  def changeset(component, attrs, %CodeMySpec.Users.Scope{} = scope) do
    component
    |> cast(attrs, [
      :name,
      :type,
      :module_name,
      :description,
      :parent_component_id,
      :synced_at,
      :files_changed_at,
      :last_analyzed_at
    ])
    |> validate_required([:name, :module_name])
    |> put_default_type()
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:module_name, min: 1, max: 255)
    |> validate_format(:module_name, ~r/^[A-Z][a-zA-Z0-9_.]*$/,
      message: "must be a valid Elixir module name"
    )
    |> validate_no_self_parent()
    |> put_scope_associations(scope)
    |> generate_deterministic_id()
    |> unique_constraint(:id, name: :components_pkey, message: "component already exists")
    |> unique_constraint([:module_name, :project_id])
    |> foreign_key_constraint(:parent_component_id)
  end

  # Generates a deterministic UUID v5 based on the module_name and project_id.
  # This ensures the same module in the same project always gets the same ID.
  @spec generate_deterministic_id(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp generate_deterministic_id(changeset) do
    # Only generate ID for new records (inserts)
    if changeset.data.__meta__.state == :built do
      module_name = get_field(changeset, :module_name)
      project_id = get_field(changeset, :project_id)

      if module_name && project_id do
        # Create a unique name combining project_id and module_name
        unique_name = "project:#{project_id}:module:#{module_name}"

        # Generate UUID v5 from namespace and unique name using the UUID library
        uuid = UUID.uuid5(@component_namespace_uuid, unique_name)

        put_change(changeset, :id, uuid)
      else
        changeset
      end
    else
      changeset
    end
  end

  @spec put_default_type(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp put_default_type(changeset) do
    case get_field(changeset, :type) do
      nil -> put_change(changeset, :type, "module")
      _type -> changeset
    end
  end

  @spec validate_no_self_parent(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_no_self_parent(changeset) do
    component_id = get_field(changeset, :id)
    parent_id = get_field(changeset, :parent_component_id)

    case {component_id, parent_id} do
      {id, id} when not is_nil(id) ->
        add_error(changeset, :parent_component_id, "cannot be its own parent")

      _ ->
        changeset
    end
  end

  # Use _id fields - always set in both web and local contexts
  @spec put_scope_associations(Ecto.Changeset.t(), CodeMySpec.Users.Scope.t()) ::
          Ecto.Changeset.t()
  defp put_scope_associations(changeset, %{
         active_account_id: account_id,
         active_project_id: project_id
       }) do
    changeset
    |> put_change(:account_id, account_id)
    |> put_change(:project_id, project_id)
  end
end
