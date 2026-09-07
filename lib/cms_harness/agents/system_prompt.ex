defmodule CmsHarness.Agents.SystemPrompt do
  @moduledoc """
  The system prompt an agent starts with: what it is for, then how this project
  works.

  Two halves, composed here because neither side has both. The role brief comes
  from the server — role semantics are the framework's, and
  `CodeMySpec.Agents.RoleBrief` keeps them beside the tool list that enforces
  them. The project guide is read here, because the server has no disk and
  `.code_my_spec/AGENTS.md` is per-project and already written.

  Nothing was sent at all before this. `Alloy.Agent.Config` accepts a
  `:system_prompt` and defaults it to nil, and no caller ever set one — so an
  agent's role decided which tools it had and never what it was for. Issue
  `0f022a10`.
  """

  @guide_path ".code_my_spec/AGENTS.md"

  # A guide is a page of workflow, not a codebase. This is generous for the
  # 155-line one this project ships and still refuses a file that has become
  # something else — a prompt is charged on every turn, and one that quietly
  # grew to a megabyte would be an expensive thing to discover from a bill.
  @max_guide_bytes 64 * 1024

  @doc """
  The prompt for an agent with this role in this checkout, or `nil`.

  `nil` when there is nothing worth saying, and `nil` is the right answer rather
  than an empty string: it is what `Alloy.Agent.Config` already defaults to, so
  an agent we have nothing to tell is exactly as it was before this existed.
  """
  @spec compose(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def compose(role_brief, working_copy, app_url \\ nil) do
    [role_brief, running_app(app_url), guide(working_copy)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  # Where the application is, so an agent testing it can open it.
  #
  # It cannot work this out. The address is a column on the project's main
  # working copy — `preview_url`, written when the harness brings a preview up —
  # and nothing on this side can see the database. So a QA agent with the
  # browser bound and 77 tools ready reported "no app URL has been identified"
  # and stopped, correctly refusing to guess, while the app was up the whole
  # time behind a tunnel it had never been told about.
  #
  # Always the main checkout's, whichever copy the agent is working in.
  # `record_preview_url/2` matches `main: true` and refuses everything else, so
  # a worktree has no preview of its own — the app runs on the main copy under
  # the harness, and that is the address there is.
  #
  # Nil says nothing at all rather than "there is no app", because those are
  # different and only one of them is knowable from here: a project between
  # previews looks identical to one that never had them.
  defp running_app(url) when is_binary(url) and url != "" do
    """
    The application you are working on is running at #{url}.

    That is the main checkout's preview, served under the harness — it is the
    address to point a browser at, whichever working copy you are in. Your own
    copy does not serve one.
    """
  end

  defp running_app(_url), do: nil

  # Read at start rather than sent from the server, and read fresh each time.
  #
  # An agent restarted after the guide changed gets the new one, which matters
  # because the guide is the thing a project edits when it changes how work is
  # done — and an agent running on last week's copy of it would be following
  # instructions nobody can see.
  defp guide(working_copy) when is_binary(working_copy) do
    path = Path.join(working_copy, @guide_path)

    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 and size <= @max_guide_bytes ->
        read_guide(path)

      {:ok, %{size: size}} when size > @max_guide_bytes ->
        # Named rather than silently dropped: an agent starting without its
        # project's workflow is a real difference in behaviour, and the reason
        # should not have to be inferred from how it acts.
        require Logger

        Logger.warning(
          "[SystemPrompt] #{path} is #{size} bytes, over the #{@max_guide_bytes} cap — " <>
            "starting the agent with its role brief alone"
        )

        nil

      _ ->
        nil
    end
  end

  defp guide(_working_copy), do: nil

  defp read_guide(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> nil
    end
  end
end
