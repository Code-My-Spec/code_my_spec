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
          health_route_status: String.t() | nil,
          head_commit: String.t() | nil,
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
    # A content check `Files` sync cannot answer (it records existence, never
    # a body — see `CodeMySpec.Generators`) and the server cannot read
    # directly for a harness-only project (`Environments.read_file/2` has
    # nowhere real to read from there). The harness reports it instead, the
    # same way it reports `module_name`. `nil` means "not reported yet", a
    # different state from either "ok" or "missing".
    field :health_route_status, :string
    # The checkout's own `git rev-parse HEAD` — what `Steps.image_tag/2` tags a
    # build with. The server cannot run `git` against a harness-only project's
    # environment (`Environments.cmd/4` has no working directory to run it in
    # there); the harness runs it locally on every sync and reports it, the
    # same shape as `module_name`/`health_route_status`.
    field :head_commit, :string
    field :code_repo, :string
    field :docs_repo, :string
    field :client_api_url, :string
    # Local-first content publishing (story 712): source dir on disk + the
    # user's own per-project S3 buckets / CDN host. The user's AWS keys live
    # here too, encrypted at rest via Cloak — the local CLI is the publisher,
    # so a published install (no envs/.env) needs them in the project DB.
    field :content_source_path, :string
    field :image_bucket, :string
    field :images_host, :string
    field :content_bucket, :string
    field :aws_access_key_id, CodeMySpec.Encrypted.Binary
    field :aws_secret_access_key, CodeMySpec.Encrypted.Binary
    field :aws_region, :string
    field :s3_endpoint, :string
    field :deploy_key, CodeMySpec.Encrypted.Binary
    # Deterministic SHA-256 of the deploy key (the encrypted column can't be
    # searched), letting the widget authenticate with only the key — no
    # project id. Deploy keys are 64 bytes of random, so an unsalted hash is
    # safe from brute force.
    field :deploy_key_hash, :string

    # Digest of the refresh secret a deployed app exchanges for short-lived
    # access tokens (story 971). The secret lives in the project's encrypted
    # environment; only its digest is here.
    field :cms_refresh_secret_hash, :string
    field :google_analytics_property_id, :string
    field :setup_error, :string
    field :local_path, :string
    field :client_user_id, :integer
    field :account_id, :binary_id

    # Email-on-your-domain (Mail context). `domain` is the project's sending
    # domain; `domain_verified_at` is set once the provider confirms DNS, and
    # mailboxes can only send/receive on a verified domain.
    field :domain, :string
    field :domain_verified_at, :utc_datetime
    # Resend's domain id, captured when the domain is registered with the
    # provider; used to fetch DNS records and trigger verification.
    field :resend_domain_id, :string

    # Which parts of setup this project runs. Stored as strings and read back
    # through `setup_options/1`, which is where the default lives — a project
    # that has never chosen gets everything, because setup's job is a working
    # project and a user who wants less turns it off rather than having to
    # discover what to turn on.
    #
    # `nil` and `[]` are different answers: nil is "never chosen", [] is
    # "chose none of the optional parts", and the unconditional steps still
    # run. Collapsing them would make turning everything off indistinguishable
    # from never having opened the page.
    field :setup_options, {:array, :string}

    # The checkout this project is read from when the reader is not itself a
    # checkout.
    #
    # Requirement satisfaction is per working copy, because it has always been a
    # statement about what one checkout could see. An agent asks as its own
    # copy; the UI is not a copy and has to be told which one speaks for the
    # project. In practice that is the main checkout — the one being pushed to
    # while agents work in worktrees off it — so reading from it is the
    # main-branch view without anything having to fetch main.
    #
    # Nullable. A project that has not named one has no canonical view, which is
    # a real state and a visible one, rather than a silent fallback to whichever
    # checkout answered last.
    belongs_to :default_working_copy, CodeMySpec.WorkingCopies.WorkingCopy, type: :binary_id

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

  @doc """
  A fresh deploy key.

  Here rather than in `Projects`, because two callers now mint one — creation
  and `ensure_deploy_key/2` — and a credential generated two ways eventually
  gets generated two lengths.
  """
  @spec mint_deploy_key() :: String.t()
  def mint_deploy_key,
    do: "dk_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  @doc false
  def changeset(project, attrs, user_scope) do
    project
    |> cast(attrs, [
      :name,
      :description,
      :module_name,
      :health_route_status,
      :head_commit,
      :code_repo,
      :docs_repo,
      :client_api_url,
      :content_source_path,
      :image_bucket,
      :images_host,
      :content_bucket,
      :aws_access_key_id,
      :aws_secret_access_key,
      :aws_region,
      :s3_endpoint,
      :deploy_key,
      :google_analytics_property_id,
      :status,
      :setup_error,
      :local_path,
      :client_user_id,
      :oauth_application_id,
      :domain,
      :domain_verified_at,
      :resend_domain_id,
      :setup_options,
      :default_working_copy_id
    ])
    |> validate_required([:name])
    |> validate_format(:module_name, ~r/^[A-Z][a-zA-Z0-9]*$/,
      message: "must be a valid Elixir module name"
    )
    |> validate_inclusion(:health_route_status, ~w(ok no_health_route health_route_piped))
    |> validate_format(:head_commit, ~r/^[0-9a-f]{40}$/, message: "must be a git commit SHA")
    |> validate_client_api_url()
    |> put_change(:account_id, user_scope.active_account_id)
    |> put_deploy_key_hash()
    |> unique_constraint(:deploy_key,
      name: :projects_deploy_key_hash_index,
      message: "is already in use by another project"
    )
    |> unique_constraint(:local_path,
      name: :projects_one_per_local_path,
      message:
        "is already the working directory of another project — a directory resolves to " <>
          "exactly one project, and every hook depends on that"
    )
  end

  @doc """
  Deterministic hash of a deploy key, used as a blind index so a project can be
  looked up by its (encrypted-at-rest) deploy key. Returns nil for a blank key.
  """
  def hash_deploy_key(key) when is_binary(key) and key != "" do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  def hash_deploy_key(_), do: nil

  @doc "True once the project's sending domain has been verified."
  def domain_verified?(%__MODULE__{domain_verified_at: nil}), do: false
  def domain_verified?(%__MODULE__{domain_verified_at: %DateTime{}}), do: true
  def domain_verified?(_), do: false

  @doc """
  True once the project's sending domain has been registered with the mail
  provider — `resend_domain_id` set.

  Not the same question as `domain_verified?/1`, and not implied by it: a
  project's `domain` field can be set by something other than
  `Mail.setup_domain/3` (provisioning's own domain step reads it, it does not
  write it), leaving a domain with no provider registration behind it at all.
  """
  def domain_registered?(%__MODULE__{resend_domain_id: id}), do: not is_nil(id)
  def domain_registered?(_), do: false

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
  #
  # Loopback excepted, and only loopback. A request to 127.0.0.1 never leaves
  # the machine, so there is no wire for it to be plaintext on; every browser
  # and every OAuth spec draws the same line for the same reason. It is what
  # lets a local site — the fleet's, in the spex — be a real publish target
  # rather than something recorded.
  defp validate_client_api_url(changeset) do
    case get_field(changeset, :client_api_url) do
      nil -> changeset
      "" -> changeset
      url when is_binary(url) -> validate_url_scheme(changeset, url)
      _url -> changeset
    end
  end

  defp validate_url_scheme(changeset, url) do
    url
    |> loopback?()
    |> apply_url_scheme_validation(changeset)
  end

  defp loopback?(url) do
    case URI.parse(url) do
      %URI{host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  defp apply_url_scheme_validation(true, changeset), do: changeset

  defp apply_url_scheme_validation(false, changeset) do
    validate_format(changeset, :client_api_url, ~r/^https:\/\/.+/, message: "must use https")
  end
end
