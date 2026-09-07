defmodule CodeMySpecWeb.ChatLiveThinkingTest do
  @moduledoc """
  The page says it is working, and can still be looked at while it does.

  Issue cbba9c41. `handle_event("send", ...)` called `Runner.run/2` — the whole
  server-side agent loop, up to twelve provider round trips — in the LiveView's
  own process. Nothing could re-render, no other event could be handled, and no
  progress could be shown until it finished.

  The indicator built to say so was unreachable: `:thinking?` was assigned
  `false` at mount and `false` again after the blocking call returned, and `true`
  nowhere, so `<div :if={@thinking?} data-test="chat-thinking">` never rendered.

  On `/app/projects/:id/chat`, the first surface after signup, that means
  somebody types, presses send, and watches a still page for as long as the model
  takes — with "thinking" and "broken" looking identical and the control that
  exists to separate them switched off.

  ## Why these turn the async flag back on

  Test config runs the turn inline, because a task in another process cannot see
  the sandbox transaction. That is right for every other test of this page — they
  want the finished turn — and it is exactly wrong here, because the inline path
  is the one that never waits. So these assert on the assign the async path sets,
  with the flag on and no turn allowed to complete.
  """

  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp with_async_turns(fun) do
    prior = Application.get_env(:code_my_spec, :chat_turn_async)
    Application.put_env(:code_my_spec, :chat_turn_async, true)

    try do
      fun.()
    after
      case prior do
        nil -> Application.delete_env(:code_my_spec, :chat_turn_async)
        value -> Application.put_env(:code_my_spec, :chat_turn_async, value)
      end
    end
  end

  defp chat(conn, project_id) do
    {:ok, live, _html} = live(conn, "/app/projects/#{project_id}/chat")
    live
  end

  test "sending shows the indicator instead of freezing", %{conn: conn, scope: scope} do
    with_async_turns(fn ->
      live = chat(conn, scope.active_project_id)

      refute has_element?(live, "[data-test='chat-thinking']"),
             "the page claimed to be working before anybody asked it to"

      html =
        live
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

      assert html =~ "chat-thinking",
             "the page did not say it was working. `:thinking?` used to be written " <>
               "false twice and true nowhere, so the indicator was unreachable code and " <>
               "a still page was the only feedback a new user got."
    end)
  end

  test "the page still answers while a turn is in flight", %{conn: conn, scope: scope} do
    with_async_turns(fn ->
      live = chat(conn, scope.active_project_id)

      live
      |> form("[data-test='chat-compose']", %{message: "Something that takes a while."})
      |> render_submit()

      # The point of not blocking: the process is free. Rendering is the cheapest
      # proof that it is — a LiveView running a twelve-round agent loop inline
      # could not have answered this at all.
      assert render(live) =~ "chat-thinking",
             "the LiveView did not respond while a turn was running, which is the " <>
               "freeze itself rather than a missing indicator."
    end)
  end

  test "a turn that dies clears the indicator too", %{conn: conn, scope: scope} do
    with_async_turns(fn ->
      live = chat(conn, scope.active_project_id)

      live
      |> form("[data-test='chat-compose']", %{message: "Something that will fall over."})
      |> render_submit()

      send(live.pid, {:DOWN, turn_ref(live), :process, self(), :boom})

      refute render(live) =~ "chat-thinking",
             "a crashed turn left the page saying it was working. That is the one " <>
               "outcome worse than the freeze this replaced: an indicator that is " <>
               "wrong rather than absent, and nothing will ever come to correct it."
    end)
  end

  test "a finished turn clears the indicator", %{conn: conn, scope: scope} do
    with_async_turns(fn ->
      live = chat(conn, scope.active_project_id)

      live
      |> form("[data-test='chat-compose']", %{message: "A booking tool."})
      |> render_submit()

      # What a finished task sends: `{ref, result}` against the ref the page is
      # holding. Sent directly rather than waited for, because what is under
      # test is that the ending clears the wait — the turn itself belongs to
      # `Runner` and is tested there.
      send(live.pid, {turn_ref(live), :ok})

      refute render(live) =~ "chat-thinking",
             "the indicator outlived the turn, so the page says it is working forever " <>
               "— which is worse than never saying it, because it is wrong rather than " <>
               "merely absent."
    end)
  end

  defp turn_ref(live) do
    :sys.get_state(live.pid).socket.assigns.turn
  end
end
