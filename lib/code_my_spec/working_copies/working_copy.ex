defmodule CodeMySpec.WorkingCopies.WorkingCopy do
  @moduledoc """
  One working copy the server knows about.

  The grain that files and problems belong to. A project id is shared by every
  checkout of a project; this is not, which is the whole point — a manifest is
  a statement about one checkout, and reconciling two of them against one set
  of rows makes each sync delete what the other just wrote.

  `label` is the harness's own description of itself and is display only. Two
  checkouts may carry the same label — two containers at `/workspace/app` on
  hosts with generated names produce identical strings — and still be two
  harnesses. That collision is exactly why identity is issued here instead of
  derived from anything the client can see.

  `root` is the same kind of thing: reported, not identifying. It is where the
  harness says its working copy is, recorded so a hook that names an id can be
  answered with a directory. Nothing resolves a harness *by* it — that was the
  old routing, and a path that had to be guessed at by walking up to the
  nearest `mix.exs` resolved one session to different roots depending on which
  subdirectory it fired from.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          label: String.t() | nil,
          main: boolean(),
          root: String.t() | nil,
          last_seen_at: DateTime.t() | nil,
          path_missing_since: DateTime.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "working_copies" do
    field :label, :string
    field :root, :string
    field :last_seen_at, :utc_datetime_usec

    # When the harness serving this copy last reported that nothing is at its
    # root any more — nil while the checkout is there, and nil before anybody
    # has looked.
    #
    # Those two are deliberately one state. Neither is a reason to warn: a copy
    # nobody has reported on has not gone anywhere, it has merely not been
    # spoken about, and the whole point of keying on a path rather than on a
    # clock is that silence stops meaning anything.
    field :path_missing_since, :utc_datetime_usec

    # Whether this is the checkout the project's own agent runs in.
    #
    # Designated, never inferred — six checkouts of one repository, several of
    # them worktrees of each other, and nothing about a path or a timestamp
    # picks the one the work belongs to. At most one per project, held by a
    # partial unique index rather than by whoever remembers to clear the others.
    field :main, :boolean, default: false

    # The machine this checkout is on. Nullable and staying that way: a copy
    # onboarded before devices existed has none until its daemon reconnects and
    # says which machine it is announcing from. That is a real state — "we have
    # not been told" — and different from a copy whose device is known.
    belongs_to :device, Device

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(harness, attrs) do
    harness
    |> cast(attrs, [
      :label,
      :last_seen_at,
      :path_missing_since,
      :project_id,
      :root,
      :device_id,
      :main
    ])
    |> validate_required([:project_id])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:main,
      name: :working_copies_one_main_per_project_index,
      message: "this project already has a main working copy"
    )
    |> unique_constraint([:project_id, :device_id, :root],
      name: :working_copies_project_device_root_index,
      message: "this machine already has a checkout at that path on this project"
    )
  end
end
