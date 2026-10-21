defmodule CodeMySpec.Devices.Device do
  @moduledoc """
  One machine that runs a harness.

  The grain above a working copy. A device runs a harness; that harness serves
  one or more checkouts; each checkout runs one or more agents. This row is the
  machine, and it exists because several facts belong to the machine and were
  being kept — badly — on the checkout instead.

  `hostname` is what the box calls itself and is display only. It is emphatically
  not identity, for the reason the working copy's id is issued rather than
  derived: a container's hostname is generated, so exactly the machines most
  likely to collide are the ones whose names cannot tell them apart. The server
  issues the id and the daemon writes it down.

  `kind` is `:local` or `:cloud`, and it is *reported* rather than inferred. The
  daemon knows which it is when it connects — a laptop has an OAuth token, a
  sprite has a deploy key and a pinned project — and that answer used to be
  discarded on every request, leaving "is this in the cloud" answerable only by
  reading a hostname out of a free-text label. Nil is a real value: a device
  that has not said should read as unknown, not as a laptop.

  `last_seen_at` is the machine's own liveness and is not the same as any one
  copy's. A laptop that is closed takes every checkout on it at once; before
  this, each copy went quiet separately and nothing connected them.

  `account_id` is nullable, and that is a real state rather than a gap. A shared
  development box is not anybody's: several people work on it, it holds no
  project of its own, and requiring an account would attach it to whichever one
  happened to announce first. Same shape as `working_copies.device_id` — "this
  belongs to nobody" and "we have not been told whose this is" are one row, and
  neither is a defect.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:local, :cloud]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          hostname: String.t() | nil,
          label: String.t() | nil,
          kind: atom() | nil,
          account_id: Ecto.UUID.t() | nil,
          last_seen_at: DateTime.t() | nil,
          preview_tunnel_id: String.t() | nil,
          preview_tunnel_secret: String.t() | nil,
          provider: atom() | nil,
          token_revoked_at: DateTime.t() | nil,
          token_hash: String.t() | nil,
          token_last_used_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "devices" do
    field :hostname, :string
    field :label, :string
    # Required, and deliberately not defaulted.
    #
    # `NOT NULL` because a machine whose kind is unknown cannot answer the
    # question the field exists for, and everything downstream then carries a
    # third state forever. No default because a default is a guess, and
    # criterion 2844 names what the guess costs: "a cloud box quietly rendered
    # as somebody's laptop is a machine nobody thinks to shut down."
    #
    # Both at once means an announce that does not say what it is is refused.
    # That reaches only clients too old to send one — the current harness always
    # does, from `CmsHarness.Device.kind/0` — and it is the same population
    # whose device-less joins are already refused, for the same reason: a
    # machine that will not identify itself cannot be recorded as one.
    field :kind, Ecto.Enum, values: @kinds
    field :account_id, Ecto.UUID
    field :last_seen_at, :utc_datetime_usec

    # What this machine is carrying, as it last reported it.
    #
    # Story 1057, criterion 3324. A harness reports facts it observes about
    # itself — its preview, its tools, its head commit — and never what it runs
    # on, so a saturated box looked like several individually slow agents. The
    # remedy for that reading is restarts, which put more work on the box.
    #
    # A map because what a machine can say about itself differs by platform and
    # will grow; `load_reported_at` because a figure with no age is a figure
    # nobody should act on.
    field :load, :map
    field :load_reported_at, :utc_datetime_usec

    # The one tunnel this machine's harness runs, carrying every address of
    # every working copy on it (story 1117). The secret is returned once, at
    # creation, so it is kept here, encrypted.
    field :preview_tunnel_id, :string
    field :preview_tunnel_secret, CodeMySpec.Encrypted.Binary

    # A dev box added from a provider (story 1130). `token_hash` is the SHA-256 of
    # the token the box signs in with: the token itself is shown once, when the box
    # is added, and kept nowhere. `token_last_used_at` is the first and latest
    # sign-in with it; nil is "never connected".
    field :provider, Ecto.Enum, values: [:local, :claude_code_cloud, :docker]
    field :token_hash, :string
    field :token_last_used_at, :utc_datetime_usec
    # Story 1131: set when Sam revokes the box; the token no longer signs in.
    field :token_revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime)
  end

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc false
  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :hostname,
      :label,
      :kind,
      :account_id,
      :last_seen_at,
      :load,
      :load_reported_at
    ])
    # Refused here rather than by the database, so an announce that does not say
    # what the machine is comes back as an error somebody can read instead of a
    # `not_null_violation` on a column name.
    |> validate_required([:kind])
  end

  @doc "A dev box: a device Sam added by choosing a provider, with its token's hash."
  def dev_box_changeset(device, attrs) do
    device
    |> cast(attrs, [:label, :provider, :kind, :account_id, :token_hash])
    |> validate_required([:label, :provider, :kind, :account_id, :token_hash])
    |> validate_length(:label, max: 80)
    |> unique_constraint(:token_hash)
  end

  @doc "The box signed in with its token."
  def token_used_changeset(device, at) do
    cast(device, %{token_last_used_at: at}, [:token_last_used_at])
  end

  @doc "The box's token was revoked."
  def revoked_changeset(device, at), do: cast(device, %{token_revoked_at: at}, [:token_revoked_at])

  @doc "Whether this device is a dev box added from a provider."
  @spec dev_box?(t()) :: boolean()
  def dev_box?(%__MODULE__{token_hash: hash}), do: is_binary(hash)

  @doc "Record the tunnel this machine's harness runs — id and secret together, or neither."
  def tunnel_changeset(device, attrs) do
    device
    |> cast(attrs, [:preview_tunnel_id, :preview_tunnel_secret])
    |> validate_tunnel_pair()
  end

  defp validate_tunnel_pair(changeset) do
    id = get_field(changeset, :preview_tunnel_id)
    secret = get_field(changeset, :preview_tunnel_secret)

    if is_nil(id) == is_nil(secret),
      do: changeset,
      else: add_error(changeset, :preview_tunnel_secret, "a tunnel id and its secret go together")
  end

  @doc """
  Build a brand-new device that will insert under the machine's own id.

  Separate from `changeset/2` on purpose: `:id` belongs in the *insert* path
  only. Adding it to `changeset/2`'s cast list would let an `update` silently
  move an existing row to a different primary key the moment `attrs` happened
  to carry one — nothing calls it that way today, but nothing should have to
  reason about it either. A fresh `%Device{}` has no id to protect, so setting
  it here is safe by construction rather than by caller discipline.
  """
  @spec new_changeset(String.t(), map()) :: Ecto.Changeset.t()
  def new_changeset(id, attrs) do
    %__MODULE__{}
    |> cast(attrs, [:hostname, :label, :kind, :account_id, :last_seen_at])
    |> put_change(:id, id)
    |> validate_required([:kind, :id])
    |> unique_constraint(:id, name: :devices_pkey)
  end

  @doc """
  The shortest string that still identifies this machine.

  A name somebody chose wins; otherwise the hostname; otherwise the id's first
  segment, because a device with neither still has to be distinguishable from
  the other one like it. Never an empty string — a blank cell reads as a
  rendering bug rather than as a machine nobody has named.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{label: label}) when is_binary(label) and label != "", do: label

  def display_name(%__MODULE__{hostname: host}) when is_binary(host) and host != "", do: host

  def display_name(%__MODULE__{id: id}) when is_binary(id), do: String.slice(id, 0, 8)

  def display_name(%__MODULE__{}), do: "unknown device"
end
