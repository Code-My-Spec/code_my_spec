defmodule CmsHarness.Web.SkillsController do
  @moduledoc """
  `POST /api/harnesses/:harness_id/skills/start` — the harness-addressed
  equivalent of `CodeMySpecLocalWeb.SkillController.start_skill/2`.

  `4396345b`: every `plugins/claude/skills/*/skill.md` posts to
  `http://localhost:4004/api/skills/start`, which is where `SkillController`
  lives on `CodeMySpecLocalWeb` — a different Phoenix app that is never
  started in light-harness mode (`CodeMySpecLocalWeb.Application.start_harness/0`
  boots only `CmsHarness.Supervisor`). `CmsHarness.Web.Endpoint` also only
  parses JSON, and the skill.md curl sends `--data-urlencode`, so the request
  never even reached a router before this — it 415'd on content type.

  Resolution mirrors `HooksController`'s exactly: the id in the URL names a
  working copy (`WorkingCopies.root/1`), which names a project
  (`Projects.ensure_started/1`), whose channel is asked to do the work
  (`ChannelClient.start_skill/2` here, `decide_hook/3` there) — the server
  computes the answer, this only carries the question and the reply.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Projects
  alias CmsHarness.WorkingCopies

  def start(conn, params) do
    case locate(params) do
      {:ok, working_dir} ->
        conn |> put_status(200) |> json(decide(working_dir, params))

      {:unknown_harness, id} ->
        Logger.warning("[CmsHarness] skills/start names harness #{id}, which this machine does not serve")
        conn |> put_status(200) |> json(%{error: "unknown_harness", harness_id: id})

      {:server_unreachable, id, reason} ->
        Logger.warning(
          "[CmsHarness] skills/start could not resolve harness #{id}: the server is " <>
            "unreachable (#{inspect(reason, limit: 5)})"
        )

        conn |> put_status(200) |> json(%{error: "server_unreachable", harness_id: id})

      :no_harness ->
        Logger.warning("[CmsHarness] skills/start arrived naming no harness")
        conn |> put_status(200) |> json(%{error: "no_harness"})
    end
  end

  # Same identity rule `HooksController.locate/2` documents: the URL's
  # `harness_id` is what `mix cms.harness.onboard` writes into the plugin, so
  # a request names the working copy it is about rather than the directory it
  # happened to fire in.
  defp locate(params) do
    case params["harness_id"] do
      id when is_binary(id) and id != "" -> from_id(id)
      _ -> :no_harness
    end
  end

  defp from_id(id) do
    case WorkingCopies.root(id) do
      {:ok, root} -> {:ok, root}
      :unknown -> {:unknown_harness, id}
      {:unreachable, reason} -> {:server_unreachable, id, reason}
    end
  end

  defp decide(working_dir, params) do
    case Projects.ensure_started(working_dir) do
      {:ok, project} -> ask(project, params)
      {:error, {:invalid_config, _}} -> refuse(:invalid_config, working_dir)
      {:error, :unreadable_config} -> refuse(:invalid_config, working_dir)
      {:error, _reason} -> refuse(:no_project, working_dir)
    end
  end

  defp ask(project, params) do
    case ChannelClient.start_skill(project.root, params) do
      {:ok, result} when is_map(result) ->
        result

      {:error, :not_connected} ->
        refuse({:not_connected, CmsHarness.Config.probe_server()}, project.root)

      {:error, :no_credential} ->
        refuse(:no_credential, project.root)

      {:error, :no_reply} ->
        refuse(:no_reply, project.root)

      other ->
        refuse({:refused, other}, project.root)
    end
  end

  defp refuse(reason, working_dir) do
    Logger.warning("[CmsHarness] skills/start refused for #{working_dir}: #{inspect(reason)}")
    %{error: "The CodeMySpec harness could not start this skill: #{inspect(reason)}"}
  end
end
