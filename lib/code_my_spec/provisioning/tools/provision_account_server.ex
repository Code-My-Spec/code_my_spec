defmodule CodeMySpec.Provisioning.Tools.ProvisionAccountServer do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Tools.Starter

  @impl true
  def name, do: "provision_account_server"

  @impl true
  def description do
    """
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
    linked keeps its machine identity. A conflicting provider resource ID is refused. Safe to
    call again for a box whose registry or database came up short the first
    time; both container checks start from "is this already true" before doing
    anything.

    ## Returns when the run starts, not when it finishes

    Creating a box, waiting for it to boot over SSH, and checking its registry
    and database containers can run well past the code-mode sandbox's 30s wall
    clock (issue 4f7929e4) — this used to call `Steps.provision_account_server/3`
    synchronously and risk a `:brutal_kill` mid-creation, with no cleanup able
    to run. The name is still linked synchronously, so a caller can trust it is
    on file the moment this returns; then a spawned task claims this account's
    own lock and only then acks, the same handshake `run_provisioning_step`
    uses. The reply is "started" or "already running"; an agent that started it
    is messaged the outcome, any other caller calls this tool again to check.

    The lock is the ACCOUNT's, not a project's: the box, its registry and its
    database are shared by every project the account has, so two projects
    racing to provision the same account's server must share one lock rather
    than each getting their own and racing the provider directly.

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
  end

  @impl true
  def params do
    %{
      name:
        {:required,
         {:meta, :string,
          [
            description:
              "The server's name at the provider — an existing box to adopt as the account's, or a new one to create under this name."
          ]}}
    }
  end

  @impl true
  def call(%{name: name}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, account_id} <- account_id(scope),
         {:ok, _linked} <- CodeMySpec.Devices.link_provider_machine(scope, %{name: name}) do
      starter = Starter.new(scope, context, name)

      scope
      |> start_provision_async(account_id, name, starter)
      |> reply(name, context)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp account_id(%{active_account_id: id}) when is_binary(id), do: {:ok, id}
  defp account_id(%{active_account: %{id: id}}) when is_binary(id), do: {:ok, id}
  defp account_id(_scope), do: {:error, :missing_active_account}

  # `provisioning_run_async` is the same flag `run_provisioning_step` reads —
  # one switch for "does a spawned task genuinely outlive this call", not a
  # second one per tool. `config/test.exs` pins it false so every existing
  # test (and every test that does not explicitly flip it) keeps running
  # this inline, on the caller's own Sandbox connection.
  defp start_provision_async(scope, account_id, name, starter) do
    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true ->
        spawn_provision_async(scope, account_id, name, starter)

      _ ->
        RunLock.with_lock(account_id, fn -> Steps.provision_account_server(scope, name, []) end)
    end
  end

  # `Resources.fix_async/3`'s handshake, for this one run: the spawned task
  # claims `RunLock` first and only then signals, so the caller learns
  # "running" or "refused" in milliseconds. The task runs under
  # `CodeMySpec.TaskSupervisor`, out of reach of this call's own timeouts, and
  # (via `$callers`, which `Task.Supervisor.start_child/2` sets) still reaches
  # whatever `Req.Test` stub or Sandbox connection the spawning process holds.
  defp spawn_provision_async(scope, account_id, name, starter) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        RunLock.with_lock(
          account_id,
          fn ->
            send(parent, {ref, :locked})
            Steps.provision_account_server(scope, name, [])
          end,
          Starter.lock_holder(starter)
        )
        |> case do
          {:error, {:already_running, _}} = refused ->
            send(parent, {ref, refused})

          finished ->
            Starter.tell(starter, outcome_message(finished, name))
        end
      end)

    receive do
      {^ref, :locked} -> {:ok, :started}
      {^ref, {:error, {:already_running, _}} = refused} -> refused
    after
      5_000 -> {:error, :lock_handshake_timeout}
    end
  end

  defp reply({:ok, :started}, name, context) do
    {:ok, "#{name} is starting — #{then_what(context[:agent_id])}"}
  end

  # The synchronous (test-mode) outcome: `Steps.provision_account_server/3`'s
  # own result.
  defp reply({:ok, server}, name, _context), do: ok(name, server)

  defp reply({:error, {:already_running, started_at}}, _name, _context) do
    since = started_at && " (started #{started_at})"

    {:error,
     "a server run is already in progress for this account#{since} — call this " <>
       "tool again to check, rather than retrying"}
  end

  defp reply({:error, :lock_handshake_timeout}, name, _context) do
    {:error, "could not confirm #{name} started — try again shortly"}
  end

  defp reply({:error, reason}, _name, _context), do: error(reason)

  defp then_what(agent_id) when is_binary(agent_id),
    do: "you'll be messaged how it ends. Don't poll; end your turn if nothing else is waiting."

  defp then_what(_agent_id),
    do: "call this tool again to check — a run already in progress answers at once"

  defp success_text(name, server) do
    address = get_in(server, ["public_net", "ipv4", "ip"]) || "no address yet"

    "#{name} is up at #{address}, linked to the account, with its registry and " <>
      "database ready for a project to link an environment onto."
  end

  defp ok(name, server), do: {:ok, success_text(name, server)}

  @doc false
  def outcome_message({:ok, server}, name), do: success_text(name, server)

  def outcome_message({:error, reason}, name),
    do: "Could not bring up #{name}: #{inspect(reason)}"

  defp error(:missing_active_account),
    do: {:error, "No active account on this scope — cannot say whose lock to take."}

  defp error(reason),
    do: {:error, "Could not bring up the server: #{inspect(reason)}"}
end
