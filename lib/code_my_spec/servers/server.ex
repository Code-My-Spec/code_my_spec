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

  ## Why `environment` is a string and not an enum

  It is the one thing here that is Sam's answer rather than the provider's:
  what this box is *for*. Two boxes running the same image differ only in what
  he does to them — Resend belongs on the one serving real mail and not on the
  one he breaks before lunch — and nothing but a label can tell them apart.

  A free string, because `prod` is a value and not a concept the code branches
  on. `provisioning_environments` exists precisely to stop `["prod", "uat"]`
  being a literal repeated through the steps; an enum here would put it back,
  and could not hold `qa-story-812` at all.

  Nullable, and that state means something: nobody has said what this box is
  for. A machine still running from a project abandoned in March is exactly
  the one that has no label and the one most worth showing.
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
    field :environment, :string

    belongs_to :account, CodeMySpec.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(server, attrs) do
    server
    |> cast(attrs, [:name, :provider, :account_id, :environment])
    |> validate_required([:name, :provider, :account_id])
    |> normalise_environment()
    |> validate_length(:environment, max: 255)
    |> unique_constraint([:account_id, :provider, :name])
    |> foreign_key_constraint(:account_id)
  end

  # An empty box in the form means "unlabelled", which is nil — not "", which
  # would be a second way to say the same thing and would sort and compare
  # differently everywhere it was read.
  defp normalise_environment(changeset) do
    case get_change(changeset, :environment) do
      nil -> changeset
      value -> put_change(changeset, :environment, blank_to_nil(String.trim(value)))
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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
      {:ok, _} ->
        {:ok,
         server
         |> Map.put(:linked, true)
         |> Map.put(:missing, false)
         |> Map.put_new(:environment, nil)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def link(_scope, _server), do: {:error, :no_account}

  @doc """
  Changeset for the one field the form edits.

  Separate from `changeset/2` so a form cannot rename a server or move it to
  another provider — the name is the provider's, not ours, and editing it here
  would silently unlink the box rather than rename anything.
  """
  @spec environment_changeset(t(), map()) :: Ecto.Changeset.t()
  def environment_changeset(server, attrs) do
    server
    |> cast(attrs, [:environment])
    |> normalise_environment()
    |> validate_length(:environment, max: 255)
  end

  @doc """
  The linked record for a name, or nil.

  Only meaningful once linked: the label is Sam's answer about a box he has
  claimed, and there is nowhere to keep it for one he has not.
  """
  @spec get_linked(Scope.t(), String.t()) :: t() | nil
  def get_linked(%Scope{active_account_id: account_id}, name)
      when is_binary(account_id) and is_binary(name) do
    Repo.get_by(__MODULE__, account_id: account_id, provider: "hetzner", name: name)
  end

  def get_linked(_scope, _name), do: nil

  @doc """
  Save an edited server. Scope-checked by having been fetched through
  `get_linked/2`, which is the only way a caller gets the struct.
  """
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = server, attrs) do
    server |> environment_changeset(attrs) |> Repo.update()
  end

  @doc """
  What this account has linked, as `name => environment`.

  A map rather than a set because every caller that asks whether a box is
  linked also wants to know what it is for, and two queries would let the two
  answers disagree. An unlabelled server is present with a `nil` value, which
  is why membership is tested with `Map.has_key?/2` and never by truthiness.
  """
  @spec linked_environments(Scope.t()) :: %{String.t() => String.t() | nil}
  def linked_environments(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    __MODULE__
    |> where([s], s.account_id == ^account_id)
    |> select([s], {s.name, s.environment})
    |> Repo.all()
    |> Map.new()
  end

  def linked_environments(_scope), do: %{}

  @doc """
  A linked server the provider no longer reports.

  Kept in the list rather than dropped: things still point at it, and its
  address has already been handed to somebody else. The screen is the only
  place that can say so.
  """
  @spec placeholder(String.t(), String.t() | nil) :: map()
  def placeholder(name, environment \\ nil) do
    %{
      id: nil,
      name: name,
      ip: nil,
      size: nil,
      architecture: nil,
      location: nil,
      status: nil,
      linked: true,
      missing: true,
      unverified: false,
      environment: environment
    }
  end
end
