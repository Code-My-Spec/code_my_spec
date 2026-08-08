defmodule CodeMySpec.Resources.Acknowledgement do
  @moduledoc """
  A record that a resource is there on purpose.

  ## Why it is not a flag on a resource

  The resources page rebuilds its list from the providers on every load — that
  is what makes it worth trusting, and it means a resource is not a row that
  can carry a flag. It is whatever Hetzner said thirty seconds ago.

  So this keys on what survives a rebuild: the kind and the location. Nothing
  about our record of the thing, because the resources that most need marking
  are exactly the ones setup never created and has no record of.

  ## What it buys

  Deleting becomes safe to offer. Without it the page keeps reporting
  deliberate leftovers as broken, and a red mark that is wrong often enough
  stops being read — which costs more than the resource does.

  Distinct from `Provisioning.Resource.origin`, which says who *created* a
  resource we know about. This says who wants it kept.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "resource_acknowledgements" do
    field :kind, :string
    field :location, :string
    field :note, :string

    belongs_to :account, CodeMySpec.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(acknowledgement, attrs) do
    acknowledgement
    |> cast(attrs, [:kind, :location, :note, :account_id])
    |> validate_required([:kind, :location, :account_id])
    |> unique_constraint([:account_id, :kind, :location])
    |> foreign_key_constraint(:account_id)
  end

  @doc """
  Mark a resource as deliberate. Marking twice is a double click, not an error.
  """
  @spec keep(Scope.t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def keep(%Scope{active_account_id: account_id}, kind, location)
      when is_binary(account_id) and is_binary(kind) and is_binary(location) do
    %__MODULE__{}
    |> changeset(%{account_id: account_id, kind: kind, location: location})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:account_id, :kind, :location])
    |> case do
      {:ok, _} -> {:ok, get(account_id, kind, location)}
      {:error, reason} -> {:error, reason}
    end
  end

  def keep(_scope, _kind, _location), do: {:error, :no_account}

  @doc """
  Stop treating a resource as deliberate. Puts it back among the dangling,
  which is the point — a marking that could not be taken back would be a way
  to lose track of something permanently.
  """
  @spec release(Scope.t(), String.t(), String.t()) :: :ok
  def release(%Scope{active_account_id: account_id}, kind, location)
      when is_binary(account_id) do
    __MODULE__
    |> where([a], a.account_id == ^account_id and a.kind == ^kind and a.location == ^location)
    |> Repo.delete_all()

    :ok
  end

  def release(_scope, _kind, _location), do: :ok

  @doc """
  Everything this account has said to keep, as `{kind, location}` for
  membership tests.
  """
  @spec kept(Scope.t()) :: MapSet.t()
  def kept(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    __MODULE__
    |> where([a], a.account_id == ^account_id)
    |> select([a], {a.kind, a.location})
    |> Repo.all()
    |> MapSet.new()
  end

  def kept(_scope), do: MapSet.new()

  defp get(account_id, kind, location) do
    Repo.get_by(__MODULE__, account_id: account_id, kind: kind, location: location)
  end
end
