defmodule CodeMySpec.McpServers.Stories.Tools.EnsureAppRunning do
  @moduledoc """
  Bring up the caller's own copy of the app, starting it if it isn't already
  running. A live process is health-checked, not automatically restarted when
  HEAD moves. If it is unhealthy, the error reports the current checkout HEAD,
  the last recorded app revision, and the app log to inspect before recovery.
  A healthy app whose served revision differs from HEAD, or whose revision
  cannot be verified, returns an error refusing QA against it. The process
  stays running; restart_app refreshes it explicitly.

  Story 1108's rule: an agent on a copy can start, restart and stop its own
  copy's app. Always the caller's own copy — resolved from the connection's
  scope, never a parameter a caller could point at a different one. That is
  what makes "an agent cannot reach another copy's app" structural rather
  than a check that could be bypassed: there is nothing on this schema to
  name another copy with.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.CodeMode.Sandbox
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.AppTransport

  # A first boot compiles, which is why this was once three minutes. But a
  # script calling this tool runs under `Sandbox`'s wall clock and is handed
  # that budget less a margin, so a three-minute wait outlasted its caller,
  # the sandbox killed the script, and the caller never saw `AppTransport`'s
  # `:start_timed_out` (0b1ae6fc). Derived from the sandbox rather than
  # declared, so the wait always fits inside the script.
  #
  # The margin must cover `AppTransport.call_grace_ms/0` too: `AppTransport`
  # adds that grace on top of whatever timeout it is given, so a margin
  # smaller than the grace lets the actual `GenServer.call` deadline land
  # past the sandbox's own kill time -- the exact failure 0b1ae6fc fixed,
  # reintroduced one layer down once the grace existed (4d727b2c).
  @machine_call_safety_ms 500

  @doc "How long this tool waits — never longer than the script that calls it."
  @spec declared_timeout() :: pos_integer()
  def declared_timeout do
    margin = AppTransport.call_grace_ms() + @machine_call_safety_ms
    max(Sandbox.timeout([]) - margin, 1_000)
  end

  defp timeout, do: declared_timeout()

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, ensure_running(scope), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(refusal(reason)), frame}
    end
  end

  defp ensure_running(%{active_working_copy_id: id}) when is_binary(id) do
    case AppTransport.ensure_app_running(id, timeout()) do
      {:ok, %{status: "serving", url: url, commit: commit} = info} ->
        # What it serves, which a promote's reload moves past the launch commit.
        serving = Map.get(info, :serving_commit) || commit

        case AppTransport.qa_revision_check(info) do
          :ok ->
            Response.tool()
            |> Response.text("#{copy_name(id)} app is serving #{serving} at #{url}.")

          {:error, reason} ->
            Response.tool()
            |> Response.error(
              "#{copy_name(id)} app is running but is not verified for QA. " <> reason
            )
        end

      # A first start that outlasted its inline window: booting, not failed.
      {:ok, %{status: "starting", url: url, commit: commit}} ->
        Response.tool()
        |> Response.text(
          "#{copy_name(id)} app is starting #{commit || "unknown commit"} at #{url}. " <>
            "Its first boot is still compiling; call ensure_app_running again to see it serving."
        )

      {:ok, %{status: status, commit: commit} = info} ->
        not_serving(id, status, commit, info)

      {:error, reason} ->
        Response.tool() |> Response.error("Could not start the app: #{inspect(reason)}")
    end
  end

  defp ensure_running(_scope) do
    Response.tool()
    |> Response.error(
      "This call has no working copy of its own, so there is nothing here to start."
    )
  end

  # 048d1f4f: an agent read its own copy's app as main's, and a launch commit
  # behind HEAD as a restart that failed. Always say whose app this is, and
  # when HEAD has moved past what it serves.
  defp not_serving(id, status, commit, info) do
    last_commit = Map.get(info, :serving_commit) || commit
    head = Map.get(info, :head) || "unknown"

    reason =
      Map.get(info, :action_reason) ||
        "The harness supplied no startup diagnostics. Inspect this copy's app log before using restart_app."

    Response.tool()
    |> Response.error(
      "#{copy_name(id)} app is #{status}. Not serving. " <>
        "Last recorded app revision: #{last_commit || "unknown"}; current checkout HEAD: #{head}. " <>
        reason
    )
  end

  defp copy_name(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{main: true} = copy} -> "Main copy #{copy.root || copy.label}'s"
      {:ok, copy} -> "Your copy #{copy.root || copy.label}'s (not main's)"
      {:error, _} -> "Your copy's"
    end
  end

  defp refusal(:no_working_dir) do
    "This call names no project, so there is no working copy to start an app for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
