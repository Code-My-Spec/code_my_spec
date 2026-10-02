defmodule CodeMySpecSpex.Story1079.Criterion1656Spex do
  @moduledoc """
  Story 1079 — My chats show me what is new.
  Criterion 1656 — Chat lists are ordered by latest message, newest first.

  The chat with new activity is the first one seen: a reply to an older thread
  brings it back to the top, in the support inbox and the agent sessions list.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Chat lists put the latest activity first", criterion: 1656 do
    scenario "an older support chat gets a new message and moves to the top" do
      given_ "two users wrote in, Ann first and then Bob", context do
        ann = join_and_send(context, "ann-1656", "ann1656@example.com", "Hi, it's Ann")
        _bob = join_and_send(context, "bob-1656", "bob1656@example.com", "Hi, it's Bob")

        {:ok, Map.put(context, :ann, ann)}
      end

      when_ "Ann writes again", context do
        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/inbox")

        assert before?(html, "bob1656@example.com", "ann1656@example.com"),
               "Bob wrote last, so his chat should lead before Ann writes again"

        Phoenix.ChannelTest.push(context.ann, "send_message", %{"body" => "Ann again"})
        wait_for_channel(context.ann)

        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/inbox")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "Ann's chat is first in the inbox", context do
        assert before?(context.html, "ann1656@example.com", "bob1656@example.com"),
               "Ann has the newest message and her chat is not first"

        {:ok, context}
      end
    end

    scenario "an older agent session gets a new turn and moves to the top" do
      given_ "a coder spoke, then a QA agent spoke", context do
        coder = Fixtures.running_agent(context.scope, role: "coding")
        qa = Fixtures.running_agent(context.scope, role: "qa")

        :ok = Fixtures.agent_said(context.scope, coder, "Starting the refund fix")
        :ok = Fixtures.agent_said(context.scope, qa, "Checking the login page")

        {:ok,
         Map.merge(context, %{
           coder: coder,
           coder_chat: Fixtures.agent_conversation(context.scope, coder).id,
           qa_chat: Fixtures.agent_conversation(context.scope, qa).id
         })}
      end

      when_ "the coder speaks again", context do
        :ok = Fixtures.agent_said(context.scope, context.coder, "Refund fix pushed")

        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversations")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the coder's session is first in the list", context do
        assert session_order(context.html) == [context.coder_chat, context.qa_chat],
               "the coder spoke last and its session is not first"

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

    Phoenix.ChannelTest.push(channel, "send_message", %{"body" => body})
    wait_for_channel(channel)
    channel
  end

  defp before?(html, first, second) do
    {a, _} = :binary.match(html, first)
    {b, _} = :binary.match(html, second)
    a < b
  end

  defp session_order(html) do
    ~r/data-conversation-id="([^"]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end
end
