defmodule CmsHarness.Web.SkillsController do
  @moduledoc """
  `POST /api/harnesses/:working_copy_id/skills/start` — the harness-addressed
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

  ## Every refusal is a sentence, and the sentences are not written here

  A skill.md pipes this response straight into the agent's context, so whatever
  comes back *is* the entire error experience — there is no second place to
  look. Three branches used to answer with a bare code (`"unknown_harness"`)
  and the rest with `inspect/1` of a tuple, neither of which tells a reader
  what to do next; `6c93a317` is a session lost to one of them.

  `HookDecision.summarize/1` already turns these exact tuples into prose for
  the hook surface, so this asks it rather than writing a fourth copy —
  `HookDecision`, `McpController.message/1` and this module all answer for the
  same conditions, and prose that has to agree in three places and is linked in
  none is the shape most of these bugs have had.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.HookDecision
  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Projects

  def start(conn, params) do
    case conn.assigns.working_copy do
      {:ok, working_dir} ->
        conn |> put_status(200) |> json(decide(working_dir, params))

      # The directory said which project it is, and that project has no
      # `.cms_harness.json`. Named rather than guessed at, and the naming is the
      # remedy — this used to arrive as the literal string "unonboarded", a
      # sentinel a shell fallback produced, because the client resolved identity
      # itself. It sends where it is now and the harness resolves.
      {:not_onboarded, dir} ->
        Logger.warning("[CmsHarness] skills/start fired in #{dir}, which has not been onboarded")
        answer(conn, {:not_onboarded, dir})

      reason ->
        Logger.warning("[CmsHarness] skills/start could not locate a copy: #{summary(reason)}")
        answer(conn, reason)
    end
  end

  # 200 with an `error` key, never a 4xx. The caller is `curl -s` inside a
  # markdown file with no status handling — a non-2xx loses the body, and the
  # body is the only thing that was going to help.
  defp answer(conn, reason), do: conn |> put_status(200) |> json(%{error: message(reason)})

  defp message({:not_onboarded, dir}) do
    "#{dir} has not been onboarded, so there is no harness to run the skill. Run " <>
      "`mix cms.harness.onboard #{dir}` there and restart the agent. The MCP tools do " <>
      "not need onboarding and work meanwhile."
  end

  defp message(reason) do
    "The CodeMySpec harness could not start this skill: #{summary(reason)}."
  end

  defp summary(reason), do: HookDecision.summarize(reason)

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
    %{error: message(reason)}
  end
end
