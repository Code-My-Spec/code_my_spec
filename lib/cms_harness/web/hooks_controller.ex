defmodule CmsHarness.Web.HooksController do
  @moduledoc """
  Every hook, one action.

  There is nothing hook-specific here on purpose. The harness does not decide
  hooks — the server does, from the database, so that a laptop, a sprite and
  the server reach the same verdict from the same inputs. All this does is
  resolve which project the request is about, ask, and pass the answer through.

  What it does own is the failure. Three things can go wrong before an answer
  exists — no project for this directory, no connection, no reply — and each of
  them produces a refusal that names the harness and says which one it was. See
  `CmsHarness.HookDecision`.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.HookDecision
  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Projects
  alias CmsHarness.WorkingCopies

  def handle(conn, params) do
    hook = hook_name(conn)

    case locate(conn, params) do
      {:ok, working_dir} ->
        conn
        |> put_status(200)
        |> json(decide(hook, working_dir, params))

      {:unknown_harness, id} ->
        conn
        |> put_status(200)
        |> json(unknown_harness(hook, id, params))

      {:server_unreachable, id, reason} ->
        conn
        |> put_status(200)
        |> json(server_unreachable(hook, id, reason, params))

      :no_harness ->
        conn
        |> put_status(200)
        |> json(no_harness(hook, params))
    end
  end

  # A request says which working copy it is about, or it is refused. There is
  # no directory anywhere in this path and there is not going to be one: the
  # walk it replaced resolved a hook fired from a subdirectory differently from
  # one fired at the root, resolved a nested checkout to the outer one, and
  # could not tell two copies at the same path on different machines apart at
  # all.
  #
  # The id comes from the URL, which onboarding wrote by reading
  # `.cms_harness.json` — a file, per working copy, that the harness owns.
  #
  # The header is still accepted, because a host that cannot template a URL can
  # send one and the proxy forwards a real id to the server on every MCP call.
  # What is gone is the *environment variable* that used to populate it in the
  # plugin template: `X-Harness-Id: ${CMS_HARNESS_ID}` on eight hooks, with
  # nothing anywhere setting `CMS_HARNESS_ID`. It arrived unexpanded on every
  # request — 76 of them measured in one run (f32c4a4a) — and was discarded
  # here, which is the whole of "plugin hooks send no X-Harness-Id".
  #
  # Not replaced with something that sets the variable. Identity lives in the
  # config file the harness already writes; asking an operator to also export
  # it is a second source of truth that can disagree with the first.
  defp locate(conn, params) do
    case params["harness_id"] || header_id(conn) do
      id when is_binary(id) and id != "" -> from_id(id)
      _ -> :no_harness
    end
  end

  defp header_id(conn) do
    case conn |> get_req_header("x-harness-id") |> List.first() do
      value when is_binary(value) -> unexpanded(String.trim(value))
      _ -> nil
    end
  end

  # An unset variable arrives as the literal `${CMS_HARNESS_ID}`. That is a
  # plugin that was never onboarded, not an id.
  defp unexpanded("$" <> _), do: nil
  defp unexpanded(""), do: nil
  defp unexpanded(id), do: id

  defp from_id(id) do
    case WorkingCopies.root(id) do
      {:ok, root} -> {:ok, root}
      :unknown -> {:unknown_harness, id}
      {:unreachable, reason} -> {:server_unreachable, id, reason}
    end
  end

  # Named rather than guessed at. The old behaviour walked up from whatever
  # directory the hook fired in until it found a mix.exs, so an unonboarded
  # checkout silently adopted whichever project happened to be above it.
  defp unknown_harness(hook, id, params) do
    Logger.warning("[CmsHarness] #{hook} names harness #{id}, which this machine does not serve")

    HookDecision.unreachable(hook, {:unknown_harness, id}, "(addressed by id)", params)
  end

  # Separate from `unknown_harness/3` because the fix is different. There the
  # server answered and did not recognise the id, so onboarding is the answer.
  # Here the server could not be asked, and telling the reader to onboard sends
  # them to rewrite a config that was never wrong.
  defp server_unreachable(hook, id, reason, params) do
    Logger.warning(
      "[CmsHarness] #{hook} could not resolve harness #{id}: the server is unreachable " <>
        "(#{inspect(reason, limit: 5)})"
    )

    HookDecision.unreachable(hook, {:server_unreachable, id, reason}, "(addressed by id)", params)
  end

  # A hook that names nothing. Not resolvable by any means this harness is
  # willing to use, so it says how to fix it rather than guessing.
  defp no_harness(hook, params) do
    Logger.warning("[CmsHarness] #{hook} arrived naming no harness")

    HookDecision.unreachable(hook, :no_harness, "(none given)", params)
  end

  defp decide(hook, working_dir, params) do
    case Projects.ensure_started(working_dir) do
      {:ok, project} -> ask(hook, project, working_dir, params)
      {:error, {:invalid_config, _}} -> refuse(hook, :invalid_config, working_dir, params)
      {:error, :unreadable_config} -> refuse(hook, :invalid_config, working_dir, params)
      {:error, _reason} -> refuse(hook, :no_project, working_dir, params)
    end
  end

  defp ask(hook, project, working_dir, params) do
    case ChannelClient.decide_hook(project.root, hook, relativize_paths(project, params)) do
      {:ok, decision} when is_map(decision) ->
        decision

      {:error, :not_connected} ->
        # Ask the server whether it is up, so the refusal names which end is
        # broken instead of hedging. Two seconds, on a path that is already
        # failing — see `Config.probe_server/0`.
        refuse(hook, {:not_connected, Config.probe_server()}, working_dir, params)

      {:error, :no_credential} ->
        refuse(hook, :no_credential, working_dir, params)

      {:error, :no_reply} ->
        refuse(hook, :no_reply, working_dir, params)

      other ->
        # An answer the harness cannot read is not an answer. Treating an
        # unexpected shape as "fine" is the same green light as treating a
        # dropped connection as "nothing to do".
        #
        # It is not `:no_reply` either. That renders as "no answer back in
        # time", which sends whoever reads it to look at the network — while
        # the server is replying promptly and saying what is wrong. The reply
        # is carried through so the refusal quotes it.
        refuse(hook, {:refused, other}, working_dir, params)
    end
  end

  defp refuse(hook, reason, working_dir, params) do
    Logger.warning("[CmsHarness] #{hook} refused for #{working_dir}: #{inspect(reason)}")
    HookDecision.unreachable(hook, reason, working_dir, params)
  end

  @doc false
  # Claude Code names the file it just wrote with an absolute path on *this*
  # machine. The server records those to scope the next stop's block decision to
  # what this session actually touched — and it compares them against `File.path`
  # rows, which are project-relative.
  #
  # On the local harness the server relativizes them itself, against the working
  # directory it was given. A server with no disk has no working directory to
  # relativize against, so every attributed path stayed absolute, matched no File
  # row, and the changed-file set came out empty — which quietly turns every stop
  # into a quiet one, where only a previously *failed* analyzer re-runs. An agent
  # could then break a file that had compiled clean and never have it looked at
  # again.
  #
  # The harness knows its own root, so it is the right place to do this and the
  # only place that can.
  @spec relativize_paths(map(), map()) :: map()
  def relativize_paths(%{root: root}, %{"tool_input" => input} = params) when is_map(input) do
    Map.put(params, "tool_input", relativize_input(input, root))
  end

  def relativize_paths(_project, params), do: params

  defp relativize_input(input, root) do
    Enum.reduce(["file_path", "notebook_path"], input, fn key, acc ->
      case Map.get(acc, key) do
        path when is_binary(path) -> Map.put(acc, key, relative_to(path, root))
        _ -> acc
      end
    end)
  end

  # Only paths inside the checkout are rewritten. One outside it has no
  # project-relative form, and `Path.relative_to/2` answering with the original
  # is the honest result — it will match no File row, which is correct, because
  # it is not one of the project's files.
  defp relative_to(path, root) do
    case Path.type(path) do
      :relative -> path
      _ -> Path.relative_to(path, Path.expand(root))
    end
  end

  # "/api/hooks/stop" -> "stop"
  defp hook_name(conn), do: List.last(conn.path_info)
end
