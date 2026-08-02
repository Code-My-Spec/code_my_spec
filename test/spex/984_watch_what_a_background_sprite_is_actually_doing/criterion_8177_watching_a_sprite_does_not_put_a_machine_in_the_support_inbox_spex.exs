defmodule CodeMySpecSpex.Story984.Criterion8177Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 8177 — Watching a sprite does not put a machine in the
  support inbox.

  The support inbox is where a person is writing to you. A sprite is a
  machine you are watching. They must not share a queue: a sprite that
  raises an unread badge trains the operator to ignore the badge, and
  the inbox stops meaning "someone needs you".
  """

  use CodeMySpecSpex.Case
  import ReqCassette

  alias CodeMySpec.AgentHarness.ConversationRecorder

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sprite conversations stay out of the support inbox" do
    scenario "Watching a sprite does not put a machine in the support inbox" do
      given_ "a sprite has been recording its agent's turns", context do
        with_recorder_cassette("sprite_turn_before_inbox_check", fn ->
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/v1/messages", %{
            "model" => "claude-opus-5",
            "max_tokens" => 64,
            "messages" => [%{"role" => "user", "content" => "audit the requirement graph"}]
          })
        end)

        {:ok, context}
      end

      when_ "the operator opens the customer support inbox", context do
        {:ok, view, html} = live(context.conn, "/app/inbox")

        {:ok, context |> Map.put(:inbox, view) |> Map.put(:inbox_html, html)}
      end

      then_ "the sprite's conversation is not listed among the customer conversations", context do
        refute context.inbox_html =~ "audit the requirement graph",
               "a sprite's turns must not appear in the support inbox"

        refute has_element?(context.inbox, "[data-test='conversation'][data-kind='agent']"),
               "no agent conversation may be listed in the support inbox"

        {:ok, context}
      end

      and_ "no unread indicator is raised for it", context do
        refute has_element?(context.inbox, "[data-test='inbox-unread']"),
               "a sprite recording turns must not raise an unread badge on the support inbox"

        {:ok, context}
      end

      and_ "the sprite's conversation is reachable from its own project instead", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.name}/agent-conversation")

        assert html =~ "audit the requirement graph",
               "the sprite's turns must be readable on its own project's conversation"

        {:ok, context}
      end
    end
  end

  @cassette_opts [cassette_dir: "test/cassettes/anthropic"]

  # The cassette hands back a plug; the recorder picks it up from its own
  # app config, the same seam Ads uses. Restored afterwards so one spec
  # cannot leak a stubbed upstream into the next.
  defp with_recorder_cassette(name, fun) do
    with_cassette name, @cassette_opts, fn plug ->
      original = Application.get_env(:code_my_spec, ConversationRecorder, [])

      Application.put_env(
        :code_my_spec,
        ConversationRecorder,
        Keyword.put(original, :plug, plug)
      )

      try do
        fun.()
      after
        Application.put_env(:code_my_spec, ConversationRecorder, original)
      end
    end
  end

end
