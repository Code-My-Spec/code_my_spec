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
  alias CmsHarness.WorkingCopies

  # What a skill sends when it could not find an id to send.
  #
  # `skill.md` is a static marketplace file, so it cannot ask the harness who it
  # is — it greps `.cms_harness.json` and falls back to this literal via
  # `${HID:-unonboarded}`. Without matching it by name, "this copy was never
  # onboarded" arrives indistinguishable from "onboarded against an id this
  # machine does not serve", and those need opposite answers: one is a setup
  # step nobody ran, the other is a working copy pointed somewhere wrong.
  #
  # `HookDecision` cannot know about this: it is a convention between a shell
  # fallback in a markdown file and this clause, which is why it is named here
  # and not there.
  @unonboarded "unonboarded"

  def start(conn, params) do
    case locate(params) do
      {:ok, working_dir} ->
        conn |> put_status(200) |> json(decide(working_dir, params))

      :unonboarded ->
        Logger.warning(
          "[CmsHarness] skills/start from a working copy that has not been onboarded"
        )

        answer(conn, :unonboarded)

      reason ->
        Logger.warning("[CmsHarness] skills/start could not locate a copy: #{summary(reason)}")
        answer(conn, reason)
    end
  end

  # 200 with an `error` key, never a 4xx. The caller is `curl -s` inside a
  # markdown file with no status handling — a non-2xx loses the body, and the
  # body is the only thing that was going to help.
  defp answer(conn, reason), do: conn |> put_status(200) |> json(%{error: message(reason)})

  defp message(:unonboarded) do
    "This working copy has not been onboarded, so there is no harness to run the skill. " <>
      "Every skill.md reads the harness id out of `.cms_harness.json` and falls back to " <>
      "the literal \"unonboarded\" when that file is missing or has no `harness_id` — " <>
      "which is what arrived here. Run `mix cms.harness.onboard <path>` in this working " <>
      "copy and restart the agent. The MCP tools do not need onboarding and work meanwhile."
  end

  defp message(reason) do
    "The CodeMySpec harness could not start this skill: #{summary(reason)}."
  end

  defp summary(reason), do: HookDecision.summarize(reason)

  # Same identity rule `HooksController.locate/2` documents: the URL's
  # `harness_id` is what `mix cms.harness.onboard` writes into the plugin, so
  # a request names the working copy it is about rather than the directory it
  # happened to fire in.
  defp locate(params) do
    case params["harness_id"] do
      # Answered before the lookup, not after it, because there is nothing to
      # look up: this is a sentinel a shell fallback produced, not an id anyone
      # issued. Asking the server where it is makes the reply depend on whether
      # the server answers — `:unknown` when it does, `:server_unreachable` when
      # it does not — so a copy that was never onboarded got told the server was
      # unreachable, which is a different problem with a different fix. Caught by
      # the test below, which ran with no credential and therefore took the
      # second path every time.
      @unonboarded -> :unonboarded
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
    %{error: message(reason)}
  end
end
