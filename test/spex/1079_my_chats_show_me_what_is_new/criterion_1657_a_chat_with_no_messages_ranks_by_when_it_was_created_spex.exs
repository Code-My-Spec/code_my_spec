defmodule CodeMySpecSpex.Story1079.Criterion1657Spex do
  @moduledoc """
  Story 1079 — My chats show me what is new.
  Criterion 1657 — A chat with no messages ranks by when it was created.

  An empty chat has no latest message, so it takes its place from when it was
  opened. It must not float above chats with newer activity just because it
  has nothing to compare.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An empty chat ranks by when it was created", criterion: 1657 do
    scenario "a chat opened earlier with no messages sits below one written in since" do
      given_ "Cara opened a chat and wrote nothing", context do
        cara = join_and_send(context, "cara-1657", "cara1657@example.com", nil)
        {:ok, Map.put(context, :cara, cara)}
      end

      when_ "Dan writes in afterwards", context do
        _dan = join_and_send(context, "dan-1657", "dan1657@example.com", "Hello from Dan")
        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/inbox")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "Dan's chat is above Cara's empty one", context do
        assert context.html =~ "cara1657@example.com",
               "Cara's empty chat is not listed at all"

        assert before?(context.html, "dan1657@example.com", "cara1657@example.com"),
               "Cara's chat has no messages and was opened before Dan wrote, yet it is " <>
                 "listed first. An empty chat must rank by when it was created."

        {:ok, context}
      end
    end
  end

  defp join_and_send(context, end_user_id, email, body) do
    {:ok, _reply, channel} =
      CodeMySpecWeb.WidgetSocket
      |> socket("widget:#{end_user_id}", %{
        project_id: context.project.id,
        end_user_id: end_user_id,
        end_user_email: email
      })
      |> subscribe_and_join(CodeMySpecWeb.ConversationChannel, "conversation:#{end_user_id}", %{})

    say(channel, body)
    wait_for_channel(channel)
    channel
  end

  defp say(_channel, nil), do: :ok

  defp say(channel, body),
    do: Phoenix.ChannelTest.push(channel, "send_message", %{"body" => body})

  defp before?(html, first, second) do
    {a, _} = :binary.match(html, first)
    {b, _} = :binary.match(html, second)
    a < b
  end
end
