defmodule CmsHarness.Web.ResolveWorkingCopy do
  @moduledoc """
  Which working copy a request is about, resolved once, for every surface.

  Three controllers each grew their own version of this question — hooks,
  skills, analysis — and each answered it slightly differently. That is the
  shape of most of this system's quiet bugs: one rule, several implementations,
  nothing keeping them in step.

  ## What it resolves from, in order

  1. `working_copy_id` in the path, or `X-Harness-Id`. A request that names a working
     copy is more specific than one that describes where it was fired.
  2. `X-Working-Dir`, or `cwd` in the body. Every Claude Code hook payload
     carries `cwd` — the shared base in the 2.1.237 binary is `{session_id,
     transcript_path, cwd, prompt_id, permission_mode, agent_id, agent_type,
     effort}` — so a client can post the payload and set nothing at all.

  That second route is what lets a hook be a plain `curl` with nothing
  interpolated into it. It replaced a binary subcommand whose own comment
  records what the binary cost: an older copy on `PATH` did not reject
  `hook /api/hooks/stop`, it fell through to the MCP path and exited 0, so
  "eight hooks, all silently dead, and the only symptom is that nothing the
  harness should have decided ever happens". There is no version of curl that
  can be stale.

  ## Why a path is safe here and was not before

  The design that was removed had the *server* map a path to a working copy,
  where "a wrong path did not fail — it succeeded against the wrong disk". Here
  a path is only ever used to **locate the file that states an identity**, on
  the machine that path is on, and a path that finds no such file is refused
  rather than guessed at. See `CmsHarness.WorkingCopyWalk`, which also stops at
  a project boundary so an un-onboarded checkout cannot adopt its parent's id.

  ## What it does not do

  It does not refuse. Resolution and refusal are different jobs: a hook renders
  a `decision`/`reason` that Claude Code acts on, a skill renders a `prompt`,
  and MCP renders JSON-RPC. So this assigns what it found — including *why* it
  found nothing — and each controller says so in its own voice.
  """

  import Plug.Conn

  alias CmsHarness.WorkingCopies
  alias CmsHarness.WorkingCopyWalk

  @behaviour Plug

  @typedoc """
  What ended up on `conn.assigns.working_copy`.

  `{:ok, root}` — resolved.
  `{:unknown_harness, id}` — an id nothing on this machine serves.
  `{:server_unreachable, id, reason}` — the id may be fine; nobody could ask.
  `{:not_onboarded, dir}` — a project with no `.cms_harness.json` in it.
  `:no_harness` — nothing named a working copy and nothing described one.
  """
  @type resolution ::
          {:ok, String.t()}
          | {:unknown_harness, String.t()}
          | {:server_unreachable, String.t(), term()}
          | {:not_onboarded, String.t()}
          | :no_harness

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: assign(conn, :working_copy, resolve(conn))

  @doc """
  The resolution for a conn, without assigning it.

  Public so the precedence can be asserted directly rather than through a
  controller's rendering — the same reason `HarnessProjectChannel.contract_version/0`
  is.
  """
  @spec resolve(Plug.Conn.t()) :: resolution()
  def resolve(conn) do
    case named_id(conn) do
      id when is_binary(id) and id != "" -> from_id(id)
      _ -> from_directory(working_dir(conn))
    end
  end

  # Both names, new one first. The path segment is `:working_copy_id` now, and
  # the header is still `X-Harness-Id` on every plugin generated before this —
  # `plugin.json` interpolates an environment variable, so an agent that has not
  # re-onboarded keeps sending the old one until it does.
  defp named_id(conn) do
    conn.params["working_copy_id"] || conn.params["harness_id"] ||
      header(conn, "x-working-copy-id") || header(conn, "x-harness-id")
  end

  defp working_dir(conn) do
    header(conn, "x-working-dir") || conn.params["cwd"]
  end

  # An unset shell variable arrives as the literal `${CMS_HARNESS_ID}`. That is
  # a client that was never onboarded, not an id.
  defp header(conn, name) do
    case conn |> get_req_header(name) |> List.first() do
      "$" <> _ ->
        nil

      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: String.trim(value)

      _ ->
        nil
    end
  end

  defp from_id(id) do
    case WorkingCopies.root(id) do
      {:ok, root} -> {:ok, root}
      :unknown -> {:unknown_harness, id}
      {:unreachable, reason} -> {:server_unreachable, id, reason}
    end
  end

  defp from_directory(nil), do: :no_harness

  defp from_directory(dir) do
    case WorkingCopyWalk.root_for(dir) do
      {:ok, root} -> {:ok, root}
      {:error, :not_onboarded, boundary} -> {:not_onboarded, boundary}
      {:error, :outside_a_working_copy} -> :no_harness
    end
  end
end
