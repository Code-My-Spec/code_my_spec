defmodule CodeMySpec.McpServers.Devops.Tools.ProvisionAccountServer do
  @moduledoc """
  Bring up (or adopt) one account-owned server: the box itself, its shared
  registry container, and its shared database container — ready for any
  project to link an environment onto afterward.

  This is the account-level half of the hard line stories 989/990 drew:
  server and box-wide container creation live here, never in a project's own
  devops step (`run_provisioning_step`/`run_devops_setup`), which refuses to
  reach `Hetzner.create_server` under any circumstance
  (`Steps.server_creation_gate/3`). Once this tool has run, a project points
  an environment at the result with `link_server` — this tool never touches a
  project or an environment itself.

  Idempotent both ways — a name the provider already has is adopted, not
  duplicated (`Hetzner.ensure_server/3`), and a name this account has already
  linked stays linked (`Server.link/2`'s own `on_conflict: :nothing`). Safe to
  call again for a box whose registry or database came up short the first
  time; both container checks start from "is this already true" before doing
  anything.

  ## Not yet restricted by identity

  Nothing today restricts *who* may call this the way `server_creation_gate`
  restricts what a project-scoped step may do. A dedicated account-level
  agent — with its own tool set excluding this from every project-scoped
  caller structurally, not just by convention — was part of the original
  design for this split and was cut from this round of work as unnecessary
  scope. Until something like it exists, this tool is reachable the same way
  every other devops tool is: by whatever session is connected, through code
  mode. The refusal that actually matters — no project-scoped path reaches
  create-server — holds regardless, enforced in `Steps.ex` itself rather than
  by who is allowed to call this tool.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Servers.Server

  schema do
    field :name, :string,
      required: true,
      doc:
        "The server's name at the provider — an existing box to adopt as the account's, " <>
          "or a new one to create under this name."
  end

  @impl true
  def execute(%{name: name}, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, %{}),
         {:ok, _linked} <- Server.link(scope, %{name: name}),
         {:ok, server} <- Steps.provision_account_server(scope, name, []) do
      {:reply, ok(name, server), frame}
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp ok(name, server) do
    address = get_in(server, ["public_net", "ipv4", "ip"]) || "no address yet"

    Response.tool()
    |> Response.text(
      "#{name} is up at #{address}, linked to the account, with its registry and " <>
        "database ready for a project to link an environment onto."
    )
  end

  defp error(reason),
    do: Response.tool() |> Response.error("Could not bring up the server: #{inspect(reason)}")
end
