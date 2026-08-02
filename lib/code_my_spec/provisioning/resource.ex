defmodule CodeMySpec.Provisioning.Resource do
  @moduledoc """
  Something a step brought into existence, and where it lives.

  Setup's output is not a log line — it is a set of things Sam now owns and
  pays for: a server, a zone, a bucket, a sending domain. Story 963's
  criterion 7969 is that he can read back each one and go find it in the
  provider's own console, which is what `location` is for. A resource whose
  location is only in the step's prose is a resource he cannot administer.

  Embedded on `Step` rather than a table of its own: a resource has no
  identity apart from the step that created it, and re-running an idempotent
  step replaces the whole set rather than reconciling rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          kind: String.t(),
          location: String.t(),
          identifier: String.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :kind, :string
    field :location, :string
    field :identifier, :string

    # "created" or "adopted". Teardown removes only what setup created —
    # deleting a resource setup merely found destroys something the user
    # already had. Defaults to "adopted" precisely because that is the safe
    # reading of a resource whose origin nobody recorded.
    field :origin, :string, default: "adopted"
  end

  @doc false
  def changeset(resource, attrs) do
    resource
    |> cast(attrs, [:kind, :location, :identifier, :origin])
    |> validate_required([:kind, :location])
  end
end
