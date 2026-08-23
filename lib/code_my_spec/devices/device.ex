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

  alias CodeMySpec.WorkingCopies.WorkingCopy

  @kinds [:local, :cloud]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          hostname: String.t() | nil,
          label: String.t() | nil,
          kind: atom() | nil,
          account_id: Ecto.UUID.t() | nil,
          last_seen_at: DateTime.t() | nil,
          working_copies: [WorkingCopy.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "devices" do
    field :hostname, :string
    field :label, :string
    field :kind, Ecto.Enum, values: @kinds
    field :account_id, Ecto.UUID
    field :last_seen_at, :utc_datetime_usec

    has_many :working_copies, WorkingCopy

    timestamps(type: :utc_datetime)
  end

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc false
  def changeset(device, attrs) do
    device
    |> cast(attrs, [:hostname, :label, :kind, :account_id, :last_seen_at])
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
