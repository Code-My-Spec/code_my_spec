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

  alias CmsHarness.HookDecision
  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Projects

  def handle(conn, params) do
    hook = hook_name(conn)
    working_dir = working_dir(conn)

    conn
    |> put_status(200)
    |> json(decide(hook, working_dir, params))
  end

  # No working directory in the request. A sprite serves exactly one project
  # and already knows which — identity comes from CMS_PROJECT_ID/CMS_PROJECT_DIR
  # at boot, not from a header on every hook. Refusing here made a sprite whose
  # agent sent no header look like a sprite with no project.
  defp decide(hook, nil, params) do
    case configured_dir() do
      nil ->
        Logger.error(
          "[CmsHarness] #{hook} arrived with no working directory and none is configured"
        )

        HookDecision.unreachable(hook, :no_project, "(none given)", params)

      dir ->
        decide(hook, dir, params)
    end
  end

  defp decide(hook, working_dir, params) do
    case Projects.ensure_started(working_dir) do
      {:ok, project} -> ask(hook, project, working_dir, params)
      {:error, {:invalid_config, _}} -> refuse(hook, :invalid_config, working_dir, params)
      {:error, :unreadable_config} -> refuse(hook, :invalid_config, working_dir, params)
      {:error, _reason} -> refuse(hook, :no_project, working_dir, params)
    end
  end

  defp configured_dir do
    case System.get_env("CMS_PROJECT_DIR") ||
           Application.get_env(:code_my_spec, :harness_project_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> nil
    end
  end

  defp ask(hook, project, working_dir, params) do
    case ChannelClient.decide_hook(project.id, hook, relativize_paths(project, params)) do
      {:ok, decision} when is_map(decision) ->
        decision

      {:error, :not_connected} ->
        refuse(hook, :not_connected, working_dir, params)

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

  defp working_dir(conn) do
    case get_req_header(conn, "x-working-dir") do
      [dir | _] when is_binary(dir) and dir != "" -> dir
      _ -> nil
    end
  end
end
