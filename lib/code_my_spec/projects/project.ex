defmodule CodeMySpec.Projects.Project do
  @moduledoc "Schema for projects."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t(),
          description: String.t() | nil,
          module_name: String.t() | nil,
          code_repo: String.t() | nil,
          docs_repo: String.t() | nil,
          client_api_url: String.t() | nil,
          deploy_key: String.t() | nil,
          google_analytics_property_id: String.t() | nil,
          setup_error: String.t() | nil,
          local_path: String.t() | nil,
          client_user_id: integer() | nil,
          account_id: Ecto.UUID.t() | nil,
          status:
            :created
            | :setup_queued
            | :initializing
            | :deps_installing
            | :setting_up_auth
            | :compiling
            | :testing
            | :committing
            | :ready
            | :failed,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "projects" do
    field :name, :string
    field :description, :string
    field :module_name, :string
    field :code_repo, :string
    field :docs_repo, :string
    field :client_api_url, :string
    field :deploy_key, CodeMySpec.Encrypted.Binary
    # Deterministic SHA-256 of the deploy key (the encrypted column can't be
    # searched), letting the widget authenticate with only the key — no
    # project id. Deploy keys are 64 bytes of random, so an unsalted hash is
    # safe from brute force.
    field :deploy_key_hash, :string
    field :google_analytics_property_id, :string
    field :setup_error, :string
    field :local_path, :string
    field :client_user_id, :integer
    field :account_id, :binary_id

    belongs_to :oauth_application, CodeMySpec.Oauth.Application, type: :id

    field :status, Ecto.Enum,
      values: [
        :created,
        :setup_queued,
        :initializing,
        :deps_installing,
        :setting_up_auth,
        :compiling,
        :testing,
        :committing,
        :ready,
        :failed
      ],
      default: :created

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project, attrs, user_scope) do
    project
    |> cast(attrs, [
      :name,
      :description,
      :module_name,
      :code_repo,
      :docs_repo,
      :client_api_url,
      :deploy_key,
      :google_analytics_property_id,
      :status,
      :setup_error,
      :local_path,
      :client_user_id,
      :oauth_application_id
    ])
    |> validate_required([:name])
    |> validate_format(:module_name, ~r/^[A-Z][a-zA-Z0-9]*$/,
      message: "must be a valid Elixir module name"
    )
    |> validate_client_api_url()
    |> put_change(:account_id, user_scope.active_account_id)
    |> put_deploy_key_hash()
  end

  @doc """
  Deterministic hash of a deploy key, used as a blind index so a project can be
  looked up by its (encrypted-at-rest) deploy key. Returns nil for a blank key.
  """
  def hash_deploy_key(key) when is_binary(key) and key != "" do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  def hash_deploy_key(_), do: nil

  defp put_deploy_key_hash(changeset) do
    case fetch_change(changeset, :deploy_key) do
      {:ok, key} -> put_change(changeset, :deploy_key_hash, hash_deploy_key(key))
      :error -> changeset
    end
  end

  @doc """
  Changeset for bootstrapping a project from server data.

  Accepts `id` and `account_id` directly (no scope required).
  Used during init when no local project/scope exists yet.
  """
  def bootstrap_changeset(project, attrs) do
    project
    |> cast(attrs, [
      :id,
      :name,
      :description,
      :module_name,
      :code_repo,
      :docs_repo,
      :client_api_url,
      :account_id,
      :local_path,
      :client_user_id,
      :status
    ])
    |> validate_required([:id, :name, :account_id])
  end

  # The client API URL carries the deploy key (and, through it, the target app's
  # user PII) — so it must be https, never plaintext http.
  defp validate_client_api_url(changeset) do
    case get_field(changeset, :client_api_url) do
      nil -> changeset
      "" -> changeset
      _url -> validate_format(changeset, :client_api_url, ~r/^https:\/\/.+/, message: "must use https")
    end
  end
end
