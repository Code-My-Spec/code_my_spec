defmodule CodeMySpec.Oauth.DeviceGrant do
  @moduledoc """
  One RFC 8628 device-authorization request: a `device_code` the harness
  polls with, paired with the `user_code` it shows a person to type into
  the approval page.

  `device_id` is the requesting harness's own self-chosen id
  (`CmsHarness.Device`) carried as an opaque value, not an association --
  linking it back to a `CodeMySpec.Devices.Device` row is the reading
  side's job (the devices page), not this schema's.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Oauth.Application

  @type t :: %__MODULE__{
          id: integer() | nil,
          device_code: String.t() | nil,
          user_code: String.t() | nil,
          application_id: integer() | nil,
          application: Application.t() | Ecto.Association.NotLoaded.t() | nil,
          device_id: Ecto.UUID.t() | nil,
          resource_owner_id: integer() | nil,
          scopes: String.t() | nil,
          expires_at: DateTime.t() | nil,
          interval: integer() | nil,
          denied_at: DateTime.t() | nil,
          access_token_id: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "oauth_device_grants" do
    field :device_code, :string
    field :user_code, :string
    belongs_to :application, Application
    field :device_id, :binary_id
    field :resource_owner_id, :integer
    field :scopes, :string
    field :expires_at, :utc_datetime
    field :interval, :integer, default: 5
    field :denied_at, :utc_datetime
    field :access_token_id, :integer

    timestamps()
  end

  @code_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  @doc """
  Build a fresh, pending grant for `application`.

  `device_code` and `user_code` are generated here rather than accepted as
  input -- a caller names the application and the device, never the codes
  that authenticate the exchange.
  """
  @spec new_changeset(Application.t(), String.t() | nil, keyword()) :: Ecto.Changeset.t()
  def new_changeset(%Application{} = application, device_id, opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 600)
    interval = Keyword.get(opts, :interval, 5)

    %__MODULE__{}
    |> cast(
      %{
        device_code: generate_device_code(),
        user_code: generate_user_code(),
        device_id: device_id,
        scopes: Keyword.get(opts, :scopes),
        expires_at: DateTime.utc_now() |> DateTime.add(ttl_seconds, :second) |> DateTime.truncate(:second),
        interval: interval
      },
      [:device_code, :user_code, :device_id, :scopes, :expires_at, :interval]
    )
    |> put_change(:application_id, application.id)
    |> validate_required([:device_code, :user_code, :expires_at, :interval])
    |> unique_constraint(:device_code)
    |> unique_constraint(:user_code)
  end

  @doc "Mark a pending grant approved by `resource_owner_id`."
  @spec approve_changeset(t(), integer()) :: Ecto.Changeset.t()
  def approve_changeset(%__MODULE__{} = grant, resource_owner_id) do
    grant
    |> cast(%{resource_owner_id: resource_owner_id}, [:resource_owner_id])
    |> validate_required([:resource_owner_id])
  end

  @doc "Mark a pending grant denied."
  @spec deny_changeset(t()) :: Ecto.Changeset.t()
  def deny_changeset(%__MODULE__{} = grant) do
    cast(grant, %{denied_at: DateTime.utc_now() |> DateTime.truncate(:second)}, [:denied_at])
  end

  @doc """
  Record the access token minted for an approved grant, so a second poll of
  the same device_code answers with this token rather than minting another.
  """
  @spec claim_changeset(t(), integer()) :: Ecto.Changeset.t()
  def claim_changeset(%__MODULE__{} = grant, access_token_id) do
    grant
    |> cast(%{access_token_id: access_token_id}, [:access_token_id])
    |> validate_required([:access_token_id])
  end

  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, now \\ DateTime.utc_now()) do
    DateTime.compare(now, expires_at) != :lt
  end

  @spec denied?(t()) :: boolean()
  def denied?(%__MODULE__{denied_at: denied_at}), do: not is_nil(denied_at)

  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{resource_owner_id: id}), do: not is_nil(id)

  # 32 random bytes, url-safe -- opaque and long, as RFC 8628 expects of a
  # device_code. Matches this file's own generate_client_secret/0 convention.
  defp generate_device_code,
    do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  # Eight characters from an alphabet with no 0/O, 1/I/L (so a person reading
  # it off a screen or a phone never has to guess which), grouped the way RFC
  # 8628's own example ("WDJB-MJHT") reads back to a person typing it in.
  defp generate_user_code do
    code =
      1..8
      |> Enum.map(fn _ -> Enum.random(@code_alphabet) end)
      |> List.to_string()

    String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
  end
end
