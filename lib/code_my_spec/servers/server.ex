defmodule CodeMySpec.Servers.Server do
  @moduledoc """
  The record that a server matters to this account.

  Deliberately thin. Size, address, architecture and status are read from the
  provider every time they are shown, so this table holds only the link — the
  fact that Sam said "this box is mine". Caching the rest would create a second
  source of truth that drifts the moment he resizes anything in the console.

  The provider's name is the identifier rather than its id: it survives a
  resize and a reboot, and it is what Sam sees in both consoles. An id would be
  marginally more stable and considerably harder to recognise.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "linked_servers" do
    field :name, :string
    field :provider, :string, default: "hetzner"

    belongs_to :account, CodeMySpec.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(server, attrs) do
    server
    |> cast(attrs, [:name, :provider, :account_id])
    |> validate_required([:name, :provider, :account_id])
    |> unique_constraint([:account_id, :provider, :name])
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Record a server against the account, or leave it recorded if it already is.

  Upsert rather than insert: linking the same box twice is a double click, not
  an error worth showing anyone.
  """
  @spec link(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def link(%Scope{active_account_id: account_id}, %{name: name} = server)
      when is_binary(account_id) do
    %__MODULE__{}
    |> changeset(%{name: name, provider: "hetzner", account_id: account_id})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:account_id, :provider, :name]
    )
    |> case do
      {:ok, _} -> {:ok, server |> Map.put(:linked, true) |> Map.put(:missing, false)}
      {:error, reason} -> {:error, reason}
    end
  end

  def link(_scope, _server), do: {:error, :no_account}

  @doc "The names this account has linked, as a set for membership tests."
  @spec linked_names(Scope.t()) :: MapSet.t()
  def linked_names(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    __MODULE__
    |> where([s], s.account_id == ^account_id)
    |> select([s], s.name)
    |> Repo.all()
    |> MapSet.new()
  end

  def linked_names(_scope), do: MapSet.new()

  @doc """
  A linked server the provider no longer reports.

  Kept in the list rather than dropped: things still point at it, and its
  address has already been handed to somebody else. The screen is the only
  place that can say so.
  """
  @spec placeholder(String.t()) :: map()
  def placeholder(name) do
    %{
      id: nil,
      name: name,
      ip: nil,
      size: nil,
      architecture: nil,
      location: nil,
      status: nil,
      linked: true,
      missing: true
    }
  end
end
