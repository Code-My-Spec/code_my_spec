defmodule CodeMySpec.WorkingCopies.WorkingCopy do
  @moduledoc """
  One working copy the server knows about.

  The grain files and problems belong to: a manifest is a statement about one
  checkout, and two checkouts reconciled against one set of rows would delete
  each other's writes.

  `label` is display only; two checkouts may share one. `root` is reported, not
  identifying: recorded so a hook naming an id can be answered with a
  directory. Identity is the server-issued id.
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
          app_status: String.t() | nil,
          app_checked_at: DateTime.t() | nil,
          app_url: String.t() | nil,
          app_commit: String.t() | nil,
          app_serving_commit: String.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "working_copies" do
    field :label, :string
    field :root, :string
    field :last_seen_at, :utc_datetime_usec

    # When the harness first reported nothing at its root. Nil both while the
    # checkout is there and before anybody has looked — deliberately one state:
    # silence is not a reason to warn.
    field :path_missing_since, :utc_datetime_usec

    # Whether this is the checkout the project's own agent runs in, and the
    # promotion target. Designated, never inferred (except a project's only
    # checkout). At most one per project, by a partial unique index.
    field :main, :boolean, default: false

    # No git state (ahead/behind/dirty) is mirrored here: the promote gate runs
    # git live. See knowledge/promotion, "Lessons".

    # Whether the app is answering at `preview_url`, the address QA browses.
    # `serving` | `erroring` (a 500: up and failing, a QA finding) | `down`;
    # `nil` is never checked.
    field :preview_status, :string
    field :preview_checked_at, :utc_datetime_usec

    # What this copy's machine can do beyond the server's own tools (a
    # browser), reported on join and read when an agent starts here. `nil` is
    # a harness too old to report; `[]` reported none.
    field :machine_tools, {:array, :string}

    field :machine_tool_docs, :map

    # Why the tool list is what it is: `"ready"`, `"absent"` (no browser),
    # `"unreachable"` (installed, not answering — `browser_error` says why), or
    # `nil` (not said).
    field :browser_status, :string
    field :browser_error, :string

    # Where this checkout's preview answers: the main copy's, or a copy with
    # its own app that was given a tunnel (`PreviewTunnel.ensure/1`). Stored so
    # a harness restart does not lose it.
    field :preview_url, :string

    # The tunnel carrying that address. The id is public (the DNS CNAME
    # target); the secret is returned by Cloudflare once, at creation, so it is
    # stored, encrypted.
    field :preview_tunnel_id, :string
    field :preview_tunnel_secret, CodeMySpec.Encrypted.Binary

    # Every copy runs its own instance of the app. `app_url` is this copy's own
    # local address (never the tunnel); `app_commit` the commit it launched
    # from (per copy, unlike `Project.head_commit`). `app_status` is
    # `preview_status`'s three states plus `starting` (a cold first start still
    # running); `down` clears `app_url`. See `WorkingCopies.record_app_status/2`.
    field :app_status, :string
    field :app_checked_at, :utc_datetime_usec
    field :app_url, :string
    field :app_commit, :string

    # The commit the app serves now. A launch serves `app_commit`; a promote's
    # hot reload moves this one and leaves `app_commit` on the launch.
    field :app_serving_commit, :string

    # The machine this checkout is on. Nullable for rows never seen (the
    # `seen_copies_are_on_a_machine` constraint requires it once `last_seen_at`
    # is set); new mints always carry one.
    belongs_to :device, Device

    belongs_to :project, Project

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(harness, attrs) do
    harness
    |> cast(attrs, [
      # Castable so onboarding (`Staffing.mint/2`), which writes the id into
      # `.cms_harness.json` first, can insert under the same id. Insert only;
      # never pass it on update.
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
      :preview_status,
      :preview_checked_at,
      :app_status,
      :app_checked_at,
      :app_url,
      :app_commit,
      :app_serving_commit
    ])
    |> validate_required([:project_id])
    |> foreign_key_constraint(:project_id)
    # Without this, an unknown device_id (a typo, a stale device.json
    # restored onto a new machine, a reaped device row) raised
    # Ecto.ConstraintError on insert instead of returning a changeset error -
    # a 500 on the public onboarding endpoint instead of a recoverable 4xx
    # (71d28513).
    |> foreign_key_constraint(:device_id, message: "does not name a known device")
    |> CodeMySpec.Repo.References.check()
    |> unique_constraint(:main,
      name: :working_copies_one_main_per_project_index,
      message: "this project already has a main working copy"
    )
  end
end
