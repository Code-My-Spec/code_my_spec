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

    # Whether this checkout's work is on main, main's work is on it, and its
    # tree is clean — measured by the machine that holds the disk and reported
    # on every sync, because the server has no `git` to run and a graph computed
    # inside the channel process cannot ask the channel.
    #
    # `nil` means never reported, which is not the same as "in sync" and is
    # deliberately distinguishable from it.
    field :commits_ahead_of_main, :integer
    field :commits_behind_main, :integer
    field :tree_dirty, :boolean
    field :git_state_at, :utc_datetime_usec

    # Whether the application this checkout runs is answering, measured against
    # `preview_url` — the address QA browses, not a local port only this machine
    # knows.
    #
    # `serving` | `erroring` | `down`, and three rather than two because a 500 is
    # an application that came up and is failing, which is a QA finding, while a
    # refused connection is one that is not there, which is not. `nil` is never
    # checked, which is a third thing again.
    field :preview_status, :string
    field :preview_checked_at, :utc_datetime_usec

    # What this copy's machine can do beyond the server's own tools — a browser,
    # today. Reported on join, and read when an agent is started here so its
    # tool list is computed from what its machine actually has rather than from
    # what a role says it should.
    #
    # `nil` is a harness too old to report; `[]` is a machine that reported and
    # has no browser. Both give an agent no browser tools and only the second is
    # actionable.
    field :machine_tools, {:array, :string}

    field :machine_tool_docs, :map

    # Why the list beside this is empty, because `[]` covered two machines: one
    # with no browser, and one whose browser is installed and could not be
    # reached. `"absent"` and `"unreachable"` respectively, `"ready"` when there
    # are tools, and `nil` for a harness that has not said.
    #
    # The second is the one worth telling somebody about. An agent there is
    # recorded with its tools, none of which can look at a page, and until this
    # existed the only record was a warning in the harness log — it does not
    # fail, it never looks. `browser_error` carries the reason so the state is
    # actionable rather than merely distinguishable.
    field :browser_status, :string
    field :browser_error, :string

    # Where this checkout's running preview answers, when it is the one serving
    # the project. Null on every other copy, and expected to be: every worktree
    # can run the app and only one of them is the project's, so an address on a
    # sibling would be a second answer to a question with one.
    #
    # Written down rather than held by the harness, so a restart does not lose
    # it and nobody has to onboard the checkout again to get it back.
    field :preview_url, :string

    # The tunnel that carries that address to wherever the app is listening.
    #
    # The id is public — it is the CNAME target in DNS, so anyone who resolves
    # the name already has it. The secret is what lets a process claim to *be*
    # the tunnel, and Cloudflare hands it back exactly once, at creation: there
    # is nowhere to re-fetch it from, which is why it is stored rather than
    # looked up, and encrypted rather than stored plainly.
    field :preview_tunnel_id, :string
    field :preview_tunnel_secret, CodeMySpec.Encrypted.Binary

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
      # Castable so a caller that already knows this copy's id can insert under
      # it. `WorkingCopies.mint/2` writes the id into the checkout's own
      # `.cms_harness.json` before the server is told anything — the file and
      # the row are supposed to hold one value, not two derivations of one — and
      # without this the id was silently dropped and a fresh one generated.
      #
      # Only ever supplied on insert. Nothing passes it on update, and an id in
      # an update's attrs would be a caller trying to move a row rather than
      # change it.
      :id,
      :label,
      :last_seen_at,
      :path_missing_since,
      :project_id,
      :root,
      :device_id,
      :machine_tools,
      :machine_tool_docs,
      :browser_status,
      :browser_error,
      :main,
      :preview_url,
      :preview_tunnel_id,
      :preview_tunnel_secret,
      :commits_ahead_of_main,
      :commits_behind_main,
      :tree_dirty,
      :git_state_at,
      :preview_status,
      :preview_checked_at
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
