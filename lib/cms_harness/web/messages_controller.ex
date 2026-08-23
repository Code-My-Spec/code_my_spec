defmodule CmsHarness.Web.MessagesController do
  @moduledoc """
  The Anthropic-shaped endpoint a sprite's agent talks to.

  A sprite sets `ANTHROPIC_BASE_URL` here, so every model turn arrives as a
  plain `/v1/messages` request. The turn is forwarded unchanged and the
  upstream response returned unchanged — an agent must not be able to tell it
  is proxied, or the watching has altered the thing it set out to measure.

  The record goes to the server, not to disk. Same split as observations: the
  harness holds a working copy, the server holds what happened, and the
  operator reads it there.
  """
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Projects
  alias CmsHarness.WorkingCopies
  alias Plug.Conn.Status

  @upstream "https://api.anthropic.com"

  # `conn.body_params`, not the action's `params`: Phoenix merges the query
  # string into params, and Claude Code calls this as `/v1/messages?beta=true`.
  # Forwarding the merged map put `beta` in the JSON body, where Anthropic
  # rejects it — "Extra inputs are not permitted" — and every turn 400'd. A
  # proxy has to send the body it was given and leave the query where it was.
  def create(conn, _params) do
    params = conn.body_params

    case forward(params, forwarded_headers(conn), conn.query_string) do
      {:ok, %{status: 200, body: body}} ->
        record(conn, params, body)
        json(conn, body)

      {:ok, %{status: status, body: body}} ->
        conn |> put_status(forwardable(status)) |> json(body)

      {:error, reason} ->
        Logger.error("[CmsHarness] upstream call failed: #{inspect(reason)}")

        conn
        |> put_status(502)
        |> json(%{"type" => "error", "error" => %{"message" => "upstream unreachable"}})
    end
  end

  # A status this process can actually send.
  #
  # Forwarding upstream's status is what a proxy should do, and `put_status/2`
  # raises `ArgumentError: unknown status code` for anything outside Plug's
  # table — so a code Plug had not heard of became a 500 from *here*. Measured:
  # Anthropic returned 529 "overloaded", the agent was told "The CodeMySpec
  # harness failed to handle this hook (Internal Server Error) ... check its
  # log", and went looking at localhost:4004 for a problem that was upstream and
  # transient.
  #
  # 529 is configured now (`config :plug, :statuses`), which is the documented
  # mechanism and the right home for a code we expect. This is for the ones we
  # do not: an upstream, or something between us and it, can return anything,
  # and a proxy that raises on an unfamiliar number is a proxy that converts
  # somebody else's transient answer into our own hard failure.
  #
  # Falls back within the same class, so a client's retry logic still sees a
  # 5xx as a 5xx, and logs the original — the number is the one piece of
  # information the fallback destroys.
  defp forwardable(status) do
    _ = Status.reason_phrase(status)
    status
  rescue
    ArgumentError ->
      substitute = if status >= 500, do: 502, else: 400

      Logger.warning(
        "[CmsHarness] upstream answered #{status}, which Plug has no reason phrase for; " <>
          "forwarding #{substitute} instead. Add it to `config :plug, :statuses` if it is " <>
          "a code we expect to see."
      )

      substitute
  end

  defp forward(request, headers, query_string) do
    [
      url: base_url() <> "/v1/messages" <> query_suffix(query_string),
      json: request,
      headers: headers,
      decode_json: [keys: :strings],
      # The agent has its own retry and backoff; a second layer here turns one
      # slow turn into several and hides the latency from both ends.
      retry: false,
      receive_timeout: 600_000
    ]
    |> Req.new()
    |> Req.post()
  end

  # The record is sent after the response is composed and never awaited — see
  # ChannelClient.record_turn/2. A turn that reached the agent has succeeded
  # whatever the server later does with the record of it.
  defp record(conn, request, response) do
    case working_copy(conn) do
      # The request named a working copy and `from_id/1` could not resolve it,
      # having already logged which and why. Saying anything more here is worse
      # than saying nothing: the line below asserts the request named nothing,
      # which is the opposite of what happened, and sends the reader to re-run
      # onboarding when the actual cause was the server answering 500 mid-compile.
      #
      # Both lines were emitted for one request, one millisecond apart, on
      # 2026-08-21. `from_id/1`'s own comment is the rule this restores —
      # "saying which is the difference between 'the server is down' and 'this
      # harness is misconfigured'" — which it said and then discarded by
      # answering `nil` to both.
      :unresolved ->
        :ok

      nil ->
        Logger.warning(
          "[CmsHarness] turn not recorded: this request did not name a working copy and " <>
            "this harness serves #{length(Projects.list())} of them, so there is nothing " <>
            "to attribute it to. Point ANTHROPIC_BASE_URL at " <>
            "/api/harnesses/<working_copy_id> — `mix cms.harness.onboard` writes it."
        )

      root ->
        ChannelClient.record_turn(root, %{
          # nil, not "sprite". A sprite sets this header and means it; Claude
          # Code sends nothing, and inventing a label here is what put every
          # session into one conversation. Absent means "you work it out" — the
          # server can, from the working copy this turn was addressed to.
          "session_id" => header(conn, "x-cms-session-id", nil),
          "agent_role" => header(conn, "x-agent-role", "main"),
          "request" => request,
          "response" => response
        })
    end

    :ok
  end

  # The address first, the count second.
  #
  # `served_root/0` was the only rule, and it is right for exactly one shape: a
  # sprite, one container, one working copy, told which at boot. A developer's
  # harness serves every checkout it has a subtree for, so the count is never
  # one and every turn went unrecorded — the surface that exists to watch
  # agents was blind on the machine that runs the most of them.
  #
  # Resolved exactly as `HooksController.locate/2` does, down to the header
  # fallback and the unexpanded-variable guard: same question, same answer, and
  # a second way to resolve an id is a second way for them to disagree.
  defp working_copy(conn) do
    case conn.params["working_copy_id"] || conn.params["harness_id"] || header_id(conn) do
      id when is_binary(id) and id != "" -> from_id(id)
      _ -> served_root()
    end
  end

  defp from_id(id) do
    case WorkingCopies.root(id) do
      {:ok, root} ->
        root

      :unknown ->
        Logger.warning("[CmsHarness] turn not recorded: no working copy #{id}")
        :unresolved

      {:unreachable, reason} ->
        # Not fatal and not silent. The turn already reached the agent; what is
        # lost is the record of it, and saying which is the difference between
        # "the server is down" and "this harness is misconfigured".
        #
        # `:unresolved` rather than `nil` so `record/3` can keep that
        # distinction. Answering `nil` here made this branch indistinguishable
        # from a request that named nothing at all, and the caller then said so
        # in as many words.
        Logger.warning(
          "[CmsHarness] turn not recorded: could not resolve #{id} (#{inspect(reason)})"
        )

        :unresolved
    end
  end

  defp header_id(conn) do
    case conn |> Plug.Conn.get_req_header("x-harness-id") |> List.first() do
      "$" <> _ -> nil
      "" -> nil
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  # Still the answer when nothing names a working copy and there is only one to
  # mean. Kept so sprites already in the field record exactly as they did.
  defp served_root do
    case Projects.list() do
      [root] -> root
      _ -> nil
    end
  end

  defp header(conn, name, default) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when value != "" -> value
      _ -> default
    end
  end

  # The proxy holds no credential of its own — a sprite's agent authenticates
  # as itself. Anything else Anthropic needs rides along untouched.
  @forwarded ~w(authorization x-api-key anthropic-version anthropic-beta)

  defp forwarded_headers(conn) do
    Enum.flat_map(@forwarded, fn name ->
      case Plug.Conn.get_req_header(conn, name) do
        [value | _] -> [{name, value}]
        [] -> []
      end
    end)
  end

  defp query_suffix(""), do: ""
  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query

  defp base_url, do: System.get_env("ANTHROPIC_UPSTREAM_URL") || @upstream
end
