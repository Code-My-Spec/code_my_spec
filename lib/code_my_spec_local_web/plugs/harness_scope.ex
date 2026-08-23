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

  ## There is no fallback

  There was, until the plugin carrying `X-Harness-Id` shipped: a request with no
  id fell through to the working-directory chain. That is gone, along with
  `Plugs.WorkingDir` and `find_project_root/2`.

  A request naming no harness is refused. The alternative is guessing, and a
  guess here does not fail — it succeeds against the wrong disk. Three times
  measured: eight spec stubs written into the server's own repository during
  story 886's drill, `install_agents_md` reporting success into a checkout
  nobody named, and the analyzer compiling into the agent's tree.

  The directory has not gone anywhere; it stopped travelling. `.cms_harness.json`
  holds `{working_copy_id, project_id, root}` at the working copy's root and
  `harnesses.root` mirrors it, so the path lives in config beside the id that
  authorises it, and a moved checkout is a one-row update rather than a stale
  value on every request.
  """

  import Plug.Conn

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Users.Scope

  @behaviour Plug

  @header "x-harness-id"
  @param "harness"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case announced_id(conn) do
      nil -> missing(conn)
      raw -> raw |> String.trim() |> dispatch(conn)
    end
  end

  # The header first, then `?harness=`. Both name the same thing and neither is
  # a directory, which is the only distinction that matters here — an id in a
  # query string is the same class of fact as the one in
  # `/api/harnesses/:id/hooks/*`, which the light harness has always routed on.
  #
  # Two, because the two plugin shapes cannot use one. The published plugin is
  # installed once and serves every checkout, so it has no id at build time and
  # must interpolate `${CMS_HARNESS_ID}` into a header at request time. The
  # per-harness plugin `mix cms.harness.onboard` generates has the id in hand
  # and writes it straight into the url, where nothing needs to be set for it to
  # survive.
  #
  # An empty header does not mask a present parameter: a client that sends both
  # is answered by the header, and a client that sends a blank header and a real
  # parameter meant the parameter.
  defp announced_id(conn) do
    case conn |> get_req_header(@header) |> List.first() do
      value when is_binary(value) and value != "" -> value
      _ -> conn |> fetch_query_params() |> Map.fetch!(:query_params) |> Map.get(@param)
    end
  end

  # An empty value and an unexpanded `${CMS_HARNESS_ID}` mean the same thing:
  # the hook is configured to send an id and the environment had none to give.
  # That is a working copy which has not been onboarded, and it is named as such
  # rather than guessed at — `mix cms.harness.onboard` is what fixes it.
  defp dispatch("", conn), do: missing(conn)

  defp dispatch("$" <> _ = unexpanded, conn) do
    error(conn, 400, """
    X-Harness-Id arrived unexpanded as #{unexpanded}.

    The hook is configured to send one but CMS_HARNESS_ID is not set in this \
    working copy's environment. Run `mix cms.harness.onboard` in the checkout \
    this fired from — it writes .cms_harness.json and the id comes from there.
    """)
  end

  defp dispatch(id, conn), do: resolve(conn, id)

  defp resolve(conn, id) do
    case WorkingCopies.fetch(id) do
      {:ok, harness} ->
        # A hook arriving from a harness is proof its agent is working, and this
        # is the only place that proof is seen. Without it `last_seen_at` only
        # ever recorded the channel join, so an uninterrupted session's liveness
        # signal aged past the reclaim window while the agent was mid-task.
        WorkingCopies.mark_alive(harness)
        assign_scope(conn, harness)

      {:error, reason} ->
        refuse(conn, id, reason)
    end
  end

  # The root comes from the harness record, which mirrors what the working copy
  # wrote in `.cms_harness.json`. A hook fires from whatever directory the agent
  # happened to be in, and that is not evidence of anything.
  #
  # A harness issued before roots were recorded has none, and `for_local_project/2`
  # answers that with the project's `local_path` — still a fact the server looked
  # up, never one the request supplied.
  defp assign_scope(conn, harness) do
    root = harness.root

    case Scope.for_local_project(harness.project, root) do
      {:ok, scope} ->
        conn
        |> assign(:working_dir, root || scope.cwd)
        |> assign(:harness, harness)
        |> assign(:current_scope, %{scope | active_working_copy_id: harness.id})

      # Named as a fact about the harness, because that is what the caller can
      # act on. A 400 naming the id and the project it points at is one lookup
      # away from the cause; the old behaviour — falling through to the
      # working-directory chain — reported it as a malformed request instead.
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
    deleted; delete .cms_harness.json (or unset CMS_HARNESS_ID) to be issued a \
    new one.
    """)
  end

  defp refuse(conn, id, :invalid_id) do
    error(conn, 400, "X-Harness-Id is not a valid id: #{inspect(id)}")
  end

  # The refusal that replaced the fallback. It has to carry the fix, because the
  # request that hits it comes from a hook nobody is watching — the agent sees
  # the body and the operator sees nothing.
  defp missing(conn) do
    error(conn, 400, """
    #{conn.method} #{conn.request_path} named no harness.

    Every request names the working copy it is about, as an `X-Harness-Id` \
    header or a `?harness=` parameter. Nothing is inferred from the directory \
    the hook fired from — that guesses, and a guess here succeeds against the \
    wrong checkout.

    The id is written in .cms_harness.json at the working copy's root and \
    exported as CMS_HARNESS_ID. If neither exists, run `mix cms.harness.onboard` \
    there. If they do, the plugin sending this request is older than the header; \
    update it.
    """)
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: String.trim(message)}))
    |> halt()
  end
end
