defmodule CodeMySpec.Chat.McpToolRegistry do
  @moduledoc """
  Wraps the MCP tool components an agent already uses, so a server-side
  conversation calls exactly what a Claude Code agent calls.

  Nothing is redefined here. An Anubis tool component already publishes its
  name, its description and a JSON Schema for its arguments, which is precisely
  what `ReqLLM.Tool` wants — so a tool is that component plus a callback that
  invokes `execute/2`. Writing a second definition would be writing a second
  thing to keep in step.

  The scope comes off the conversation and is assigned into the frame.
  `Validators.validate_local_scope/2` prefers a frame-assigned scope over
  resolving one from a working directory, so the tools run unchanged and the
  working-directory fallback — which on a server would resolve to this
  repository, not the caller's project — is never reached. That is the whole
  reason this can exist without touching a single tool component.
  """

  @behaviour CodeMySpec.Chat.ToolRegistry

  alias Anubis.Server.Frame
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  # The story interview's surface. Deliberately narrow: an interview that can
  # delete a story is not an interview.
  @story_interview_tools [
    CodeMySpec.McpServers.Stories.Tools.CreateStory,
    CodeMySpec.McpServers.Stories.Tools.UpdateStory,
    CodeMySpec.McpServers.Stories.Tools.ListStories
  ]

  @impl CodeMySpec.Chat.ToolRegistry
  @spec list_tools(Conversation.t()) :: [ReqLLM.Tool.t()]
  def list_tools(%Conversation{type: :agent} = conversation),
    do: Enum.map(@story_interview_tools, &build_tool(&1, conversation))

  def list_tools(%Conversation{}), do: []

  defp build_tool(module, conversation) do
    name = tool_name(module)

    {:ok, tool} =
      ReqLLM.Tool.new(
        name: name,
        description: description(module, name),
        parameter_schema: module.input_schema(),
        callback: fn args -> dispatch(module, args, conversation) end
      )

    tool
  end

  # Anubis components don't expose name/0 without an explicit :name option; the
  # MCP-facing name is the snake_case of the last module segment.
  defp tool_name(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp description(module, name) do
    case module.__description__() do
      desc when is_binary(desc) and desc != "" -> desc
      _ -> name
    end
  end

  defp dispatch(module, args, conversation) do
    scope = scope(conversation)

    case refusal(module, scope) do
      nil ->
        frame = %Frame{assigns: %{current_scope: scope}}

        case module.execute(atomize(args), frame) do
          {:reply, response, _frame} -> {:ok, normalize(response)}
          {:error, reason} -> {:error, to_message(reason)}
        end

      message ->
        {:ok, message}
    end
  end

  # The interview produces one story. Nothing used to say so, and the rule
  # appeared to hold only because two stories with the same title trip a unique
  # index — so a model that named its second story differently, which is the
  # likely case since it would be describing something else, made one silently.
  #
  # This is the conversation's own question, not the tool's: `create_story` is
  # correct to keep working everywhere else. The conversation is one per project
  # (`story-interview:<project_id>`) and this is the *first* story, shaped at
  # signup before any code — so "has this project got a story yet" is the same
  # question as "has this interview already produced one", without a link to
  # keep in step.
  #
  # Returned as the tool result rather than an error, so the model reads it,
  # knows the story exists and can go on to update it. An error would end the
  # turn with nothing said.
  defp refusal(CodeMySpec.McpServers.Stories.Tools.CreateStory, scope) do
    case Stories.list_project_stories(scope) do
      {:ok, [story | _]} ->
        "This conversation has already produced a story: #{story.title} (id: #{story.id}). " <>
          "An interview shapes one story. Use `update_story` to change it rather than " <>
          "creating another."

      _ ->
        nil
    end
  end

  defp refusal(_module, _scope), do: nil

  # Account *and* project, with the project loaded — not just its id.
  #
  # Two different requirements, and only one of them is obvious.
  # `validate_local_scope/2` needs `active_project_id`, or it falls through to
  # resolving a working directory, which on a server is this repository rather
  # than the caller's project. But the repositories behind the tools match on
  # `%Scope{active_project: %Project{}}` — the struct. A scope carrying only
  # the id passes the validator and then dies in `create_story/2` with no
  # matching clause, several layers away from the thing that was wrong.
  defp scope(%Conversation{account_id: account_id, project_id: project_id}) do
    project = Projects.get_project_by_id(project_id)

    %Scope{
      active_account_id: account_id,
      active_project_id: project_id,
      active_project: project
    }
  end

  # ReqLLM hands the callback string-keyed args; Anubis components match atom
  # keys. The keys are the component's own schema fields, so the atoms exist.
  defp atomize(args) when is_map(args) do
    Map.new(args, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize(%{content: content}) when is_list(content) do
    content
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp normalize(other), do: inspect(other)

  defp content_text(%{"text" => text}) when is_binary(text), do: text
  defp content_text(%{text: text}) when is_binary(text), do: text
  defp content_text(_), do: ""

  defp to_message(reason) when is_binary(reason), do: reason
  defp to_message(reason), do: inspect(reason)
end
