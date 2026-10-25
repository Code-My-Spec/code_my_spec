defmodule CodeMySpec.AppInstances.Tools.OnlyTheNewestAppNoticeWaitsTest do
  @moduledoc """
  Issue 543c6d39: an agent ran `ensure_app_running` five times while it worked,
  each run's "app is down" notice waited for its turn to end, and all five
  arrived after the app was serving again. A notice still waiting is withdrawn
  when a newer one is told, or when the agent asks again and reads the answer
  itself, so at most one waits per app, and it is the newest.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.AppInstances.Tools.Starter
  alias CodeMySpecSpex.MailboxHelpers, as: H

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    ctx = H.start(ctx)
    H.busy(ctx)
    Map.put(ctx, :starter, Starter.new(ctx.scope, %{agent_id: ctx.agent.id}, "start"))
  end

  defp waiting(ctx) do
    ctx
    |> H.entries()
    |> Enum.filter(&(&1.state == :queued))
    |> Enum.map(&message_text/1)
  end

  defp message_text(entry),
    do: CodeMySpec.Repo.get!(CodeMySpec.Conversations.Message, entry.message_id).content

  test "a newer notice for the same app replaces the one still waiting", ctx do
    :ok = Starter.tell(ctx.starter, "app-1", "app is down at 4a285833")
    :ok = Starter.tell(ctx.starter, "app-1", "app is serving ee918f40")
    :ok = Starter.tell(ctx.starter, "app-2", "the other app is down")

    texts = ctx |> waiting() |> Enum.map(&inspect/1) |> Enum.join("\n")

    refute texts =~ "4a285833", "the stale notice still waits:\n#{texts}"
    assert texts =~ "ee918f40"
    assert texts =~ "the other app is down"
  end

  test "asking again withdraws the notice still waiting", ctx do
    :ok = Starter.tell(ctx.starter, "app-1", "app is down at 4a285833")
    :ok = Starter.settled(ctx.starter, "app-1")

    refute ctx |> waiting() |> inspect() =~ "4a285833"
  end
end
