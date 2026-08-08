defmodule CodeMySpecLocalWeb.Plugs.HarnessScope do
  @moduledoc """
  Resolves a request from the harness id it names.

  `X-Harness-Id` is the routing key. The id identifies the working copy, and
  the harness record says which project it serves and which directory it is —
  so the directory is an answer, never a question.

  ## Why not the working directory

  The chain this precedes takes the path a hook announces and walks up to the
  nearest `mix.exs`. That makes the same session resolve differently depending
  on which subdirectory it fired from, resolves a checkout nested under another
  to the outer one, and cannot tell two checkouts at the same path on different
  machines apart at all. Every one of those has cost us a debugging session,
  and the last produced a refusal that named the *same* root on both sides of
  "already holds this project".

  An id is none of those things. It is issued once, written down, and presented
  unchanged, so two working copies are two harnesses whatever their paths say.

  ## The fallback is temporary

  A request with no id falls through to the working-directory chain, because
  the released plugin does not send the header yet and removing the fallback
  before it ships would refuse every hook on this machine. It logs each time,
  so the remaining callers are countable rather than assumed. Once the plugin
  carrying `X-Harness-Id` is out, this becomes a refusal and
  `Plugs.WorkingDir`'s `find_project_root/2` goes with it.
  """

  import Plug.Conn

  require Logger

  alias CodeMySpec.Harnesses
  alias CodeMySpec.Users.Scope

  @behaviour Plug

  @header "x-harness-id"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn |> get_req_header(@header) |> List.first() do
      nil -> fall_back(conn)
      raw -> raw |> String.trim() |> dispatch(conn)
    end
  end

  # An empty value and an unexpanded `${CMS_HARNESS_ID}` mean the same thing:
  # the hook offered an id and the environment had none to give. Refusing those
  # would take down every hook on a machine whose variable is merely unset,
  # which is the state of every checkout until it is onboarded.
  defp dispatch("", conn), do: fall_back(conn)

  defp dispatch("$" <> _ = unexpanded, conn) do
    Logger.warning("""
    [HarnessScope] X-Harness-Id arrived unexpanded as #{unexpanded}.

    The hook is configured to send one but CMS_HARNESS_ID is not set in this \
    working copy's environment. Falling back to the working directory.
    """)

    fall_back(conn)
  end

  defp dispatch(id, conn), do: resolve(conn, id)

  defp resolve(conn, id) do
    case Harnesses.fetch(id) do
      {:ok, harness} -> assign_scope(conn, harness)
      {:error, reason} -> refuse(conn, id, reason)
    end
  end

  # The harness's own root wins over anything the request said about where it
  # is. A hook fires from whatever directory the agent happened to be in; the
  # root is what the working copy reported about itself.
  defp assign_scope(conn, harness) do
    root = harness.root || announced_root(conn)

    case Scope.for_local_project(harness.project, root) do
      {:ok, scope} ->
        conn
        |> assign(:working_dir, root)
        |> assign(:harness, harness)
        |> assign(:current_scope, %{scope | active_harness_id: harness.id})

      {:error, reason} ->
        error(conn, 400, """
        Harness #{harness.id} names project #{harness.project_id}, which could \
        not be loaded: #{inspect(reason)}.
        """)
    end
  end

  # A stale id is the interesting case and it is not the operator's fault: the
  # row can be deleted while the working copy still holds the file. Saying so
  # by name beats a 404 naming a path, which is what sent us looking at the
  # filesystem the last three times.
  defp refuse(conn, id, :not_found) do
    error(conn, 404, """
    No harness with id #{id}.

    This working copy holds an id the server does not know. The row was likely \
    deleted; delete .cms_harness_id (or unset CMS_HARNESS_ID) to be issued a \
    new one.
    """)
  end

  defp refuse(conn, id, :invalid_id) do
    error(conn, 400, "X-Harness-Id is not a valid id: #{inspect(id)}")
  end

  # Only for a harness issued before roots were recorded, which has not yet
  # reconnected to report one. Taken verbatim rather than walked up from: the
  # walk is the behaviour being retired, and a root that is merely unreported
  # is not a reason to start guessing.
  defp announced_root(conn) do
    case get_req_header(conn, "x-working-dir") do
      [dir | _] when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> nil
    end
  end

  defp fall_back(conn) do
    Logger.warning("""
    [HarnessScope] #{conn.method} #{conn.request_path} sent no X-Harness-Id; \
    falling back to resolving the working directory.

    This path guesses the working copy by walking up to the nearest mix.exs and \
    cannot tell two checkouts apart reliably. Update the plugin so its hooks \
    send X-Harness-Id.
    """)

    conn
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: String.trim(message)}))
    |> halt()
  end
end
