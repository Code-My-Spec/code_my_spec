defmodule CodeMySpecSpex.EpicHelpers do
  @moduledoc """
  The premises story 964's twelve criteria share: an epic proposed, an epic
  agreed to, and a dispatched agent that asks something or falls over.

  ## Why some of this is a remote call

  `StoryHelpers` aliases the MCP tool modules it drives, which is right and is
  only possible because those tools exist. Half of 964's surface does not exist
  yet — that is the point of writing the specs first — and an alias to a module
  nobody has written does not compile, so the specs could not even be validated.

  So the calls that name the not-yet-built contract are made remotely, by name.
  They compile, they fail at run time, and the failure is the red bar the
  implementation gets built against. Everything that *does* exist —
  `CreateEpic`, `AssignStoryToEpic`, the epics screen — is driven properly.

  `CodeMySpec.EpicDispatch` is the module those calls name. Writing them here
  fixes its public shape:

    * `propose(scope, epic_id)` — the main agent sends an epic for approval
    * `progress(scope)` — what the main agent can see about work it dispatched
    * `record_question(scope, epic_id, text)` — a dispatched agent asking
    * `record_failure(scope, epic_id, reason)` — a dispatched agent stopping

  Approval is deliberately *not* here. It happens by clicking the control on the
  epics screen, because that is where John put it, and a helper that approved
  some other way would prove the gate worked somewhere nobody uses.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpecSpex.StoryHelpers

  use CodeMySpecWeb, :verified_routes

  @endpoint CodeMySpecWeb.Endpoint

  @doc """
  An epic of `n` ready stories, sent for approval by the main agent.

  Answers the epic id. The stories are created through the same tools the agent
  uses, so what is proposed is a real epic of real stories rather than a row
  shaped like one.
  """
  @spec propose(map(), String.t(), keyword()) :: String.t()
  def propose(context, title, opts \\ []) do
    frame = %Frame{assigns: %{current_scope: context.scope}}
    count = Keyword.get(opts, :stories, 1)

    {:reply, response, _frame} =
      CreateEpic.execute(%{title: title, description: "Proposed for approval"}, frame)

    epic_id = extract_id(response)

    for n <- 1..count do
      story =
        StoryHelpers.create_and_link(context.scope, context.component.module_name,
          title: "#{title} — part #{n}",
          description: "One of the things in this epic",
          acceptance_criteria: ["It works"]
        )

      {:reply, _resp, _frame} =
        AssignStoryToEpic.execute(
          %{story_id: to_string(story.id), epic_name: title},
          frame
        )
    end

    # The half that does not exist yet. Named rather than worked around: this is
    # the call the implementation has to satisfy.
    apply(CodeMySpec.EpicDispatch, :propose, [context.scope, epic_id])

    epic_id
  end

  @doc """
  An epic proposed and then agreed to, through the control on the epics screen.

  Answers the context with `:epic` added. Approval goes through the page because
  that is the only route John kept — approving another way here would prove the
  gate works somewhere nobody uses.
  """
  @spec dispatch_one(map(), String.t(), keyword()) :: map()
  def dispatch_one(context, title, opts \\ []) do
    epic_id = propose(context, title, opts)

    {:ok, live, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

    live
    |> element("[data-test=approve-epic][data-epic-id=#{epic_id}]")
    |> render_click()

    Map.put(context, :epic, epic_id)
  end

  @doc "A dispatched agent asking the user something."
  @spec agent_asks(map(), String.t()) :: :ok
  def agent_asks(context, text) do
    apply(CodeMySpec.EpicDispatch, :record_question, [context.scope, context.epic, text])
    :ok
  end

  @doc "A dispatched agent stopping without finishing."
  @spec agent_fails(map(), String.t()) :: :ok
  def agent_fails(context, reason) do
    apply(CodeMySpec.EpicDispatch, :record_failure, [context.scope, context.epic, reason])
    :ok
  end

  @doc """
  What the main agent can see about work it dispatched.

  `source: :record` is part of the contract: the main agent reports on work it
  is not doing, so the answer has to come from what the dispatched side wrote
  down rather than from running anything.
  """
  @spec progress(map()) :: map()
  def progress(context) do
    apply(CodeMySpec.EpicDispatch, :progress, [context.scope])
  end

  defp extract_id(response) do
    text = response_text(response)

    case Regex.run(~r/\(ID: ([^)]+)\)/, text) do
      [_, id] ->
        id

      nil ->
        flunk("could not read an epic id out of: #{inspect(text)}")
    end
  end
end
