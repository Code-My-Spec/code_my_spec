defmodule CodeMySpecSpex.MainAgentHelpers do
  @moduledoc """
  Story 963's two shared premises: a project with a main checkout, and talking
  to the agent in it.

  Here rather than in each criterion because "talk to the main agent" is three
  steps — find the agent's conversation on the index, open it, submit the form
  — and the middle one is the one that gets missed. Two criteria wrote it as a
  submit against the index page, where the send form does not exist, and both
  failed in `given_` with a selector error that reads like a rendering bug.

  Both of these go through the pages a person uses. The main copy is designated
  by clicking the control that designates it, and the message is sent by
  submitting the form somebody types into — so a criterion that passes here is
  evidence about the product rather than about a context function.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.McpServers.Agents.Tools.StopAgent

  # The cloud router, because these paths are `/app` ones. `CodeMySpecSpex.Case`
  # verifies against the local router, where they do not exist — which is why
  # every spex in this story compiles with a "no route path" warning per `~p`.
  use CodeMySpecWeb, :verified_routes

  @endpoint CodeMySpecWeb.Endpoint

  @doc """
  A checkout on this machine, designated as the project's main one.

  Answers the context with `:copy` (the path) and `:copy_id` added. The path is
  real and made, because an agent is refused a checkout that is not on disk —
  and that refusal is its own criterion rather than something to work around.

  `opts` reach the join, for a criterion about something the checkout *reports*
  rather than about the checkout itself — `preview_url:` is the one that exists
  today. Empty by default, so a harness that announces nothing stays the
  ordinary case here.
  """
  @spec given_a_main_checkout(map(), String.t(), keyword()) :: map()
  def given_a_main_checkout(context, label, opts \\ []) do
    copy = CodeMySpec.TempFile.dir(label)
    File.mkdir_p!(copy)
    {joined, socket} = join_working_copy_socket(context, copy, "the main checkout", opts)

    {:ok, _live, _html} =
      live(
        context.conn,
        ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
      )

    designate_main_copy(context, joined.working_copy_id)

    # The socket is kept because a restart is driven over it. Joining a second
    # time for the same checkout is refused, correctly — two harnesses on one
    # copy share a `_build` — so the socket has to come from the join that made
    # the copy rather than from a second one beside it.
    context
    |> Map.put(:copy, copy)
    |> Map.put(:copy_id, joined.working_copy_id)
    |> Map.put(:harness_socket, socket)
  end

  @doc """
  The agent the page presents as the project's own.

  Read off the page for the same reason the conversation path is: what a
  criterion here means by "the main agent" is the one a person is shown, not the
  one a query would find.
  """
  @spec main_agent_id(map()) :: String.t()
  def main_agent_id(context) do
    {:ok, _live, html} =
      live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

    agent_id_in(html) ||
      flunk("the project presents no main agent, so there is nothing to ask")
  end

  @doc """
  The agent behind the marker, in html a criterion already has.

  So that "the same one" is a claim about identity rather than about the marker
  being present twice. `nil` when there is none, because several criteria are
  about exactly that.
  """
  @spec agent_id_in(String.t()) :: String.t() | nil
  def agent_id_in(html) do
    case Regex.run(~r/data-test="main-agent"[^>]*data-agent-id="([^"]+)"/, html) do
      [_, id] -> id
      nil -> nil
    end
  end

  @doc """
  Stop whatever the project currently presents as its main agent.

  Through the tool an operator's stop goes through, so what the scenario
  observes afterwards is the state a real stop leaves behind. Reads the id off
  the page rather than being handed one, because the criterion this serves is
  about what the *page* offers before and after.
  """
  @spec stop_main_agent(map()) :: :ok
  def stop_main_agent(context) do
    {:ok, _live, html} =
      live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

    agent_id = agent_id_in(html)

    assert agent_id,
           "there is no main agent to stop, so the scenario's premise never held"

    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    {:reply, reply, _frame} =
      StopAgent.execute(%{"agent_id" => agent_id}, frame)

    refute reply.isError, "the stop was refused, so nothing was stopped"

    :ok
  end

  @doc """
  Make that checkout the project's main one, through the control that does it.

  Does nothing when it already is, which is the ordinary case for a project's
  only checkout: the first one to report a root is designated, so the control is
  not offered and there is nothing to click. Asserted rather than assumed either
  way — a scenario whose premise is a main copy must not carry on without one.
  """
  @spec designate_main_copy(map(), String.t()) :: :ok
  def designate_main_copy(context, working_copy_id) do
    {:ok, live, html} =
      live(
        context.conn,
        ~p"/app/projects/#{context.project.id}/working-copies/#{working_copy_id}"
      )

    cond do
      html =~ "data-test=\"designate-main-copy\"" ->
        live |> element("[data-test=designate-main-copy]") |> render_click()
        :ok

      html =~ "data-test=\"main-copy\"" ->
        :ok

      true ->
        flunk(
          "this checkout is neither the main working copy nor offering to become one, " <>
            "so the premise cannot be established"
        )
    end
  end

  @doc """
  Where the project's own conversation is, as the index links to it.

  Read off the page rather than queried, because the claim every criterion here
  makes is about what a person clicking "Open" lands on. A path built from a
  conversation the criterion looked up itself would pass while the link went
  somewhere else entirely.
  """
  @spec main_conversation_path(map()) :: String.t()
  def main_conversation_path(context) do
    {:ok, _live, html} =
      live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

    case Regex.run(~r"href=\"(/app/projects/[0-9a-f-]+/agent-conversation/[0-9a-f-]{36})\"", html) do
      [_, path] ->
        path

      nil ->
        flunk(
          "the project's agent conversation is not linked from its agents page, so " <>
            "there is nothing for somebody to open"
        )
    end
  end

  @doc """
  Say something to the project's own agent, the way a person does.

  Opens the conversation from the index and submits the send form. Answers the
  conversation path, because every criterion that says something goes on to
  read the same page back.
  """
  @spec say_to_main_agent(map(), String.t()) :: String.t()
  def say_to_main_agent(context, text) do
    path = main_conversation_path(context)
    {:ok, chat, _html} = live(context.conn, path)

    chat
    |> form("form[phx-submit=send_message]", %{"message" => text})
    |> render_submit()

    path
  end
end
