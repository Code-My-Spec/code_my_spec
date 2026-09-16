defmodule CodeMySpecSpex.Story1040.Criterion3030Spex do
  @moduledoc """
  Story 1040 — I connect a model provider by pasting its API key
  Criterion 3030 — Sam starts QA and it runs on the cheap model he paid for

  What the whole story is for, end to end: a key pasted on the settings page
  becomes the credential a QA agent starts on.

  Story 1039 could already point a type at Z.ai and 1039's own QA found the
  point moot — nothing could connect Z.ai, so every type resolved to the one
  subscription an account could get. The connection is made through the page
  here rather than seeded, because a seeded row proves the launcher works and
  says nothing about whether anyone can reach it.
  """

  use CodeMySpecSpex.Case

  cloud_endpoint()

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I connect a model provider by pasting its API key" do
    scenario "Sam starts QA and it runs on the cheap model he paid for" do
      given_ "Z.ai will accept his key", context do
        Req.Test.stub(CodeMySpec.Integrations.Providers.ApiKey, fn conn ->
          Req.Test.json(conn, %{"ok" => true})
        end)

        {:ok, context}
      end

      given_ "he connects Z.ai by pasting it", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/users/settings")

        view
        |> form("[data-test='api-key-form-zai']", %{"api_key" => %{"key" => "zai-live-key"}})
        |> render_submit()

        {:ok, context}
      end

      given_ "and points QA at a cheap model on it", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/accounts/#{context.account.id}/agents")

        view
        |> form("[data-test='agent-models-form']", %{
          "qa" => %{"provider" => "zai", "model" => "glm-cheap"}
        })
        |> render_submit()

        {:ok, context}
      end

      when_ "he starts a QA agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StartAgent.execute(%{role: "qa"}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it reports the provider and model he chose", context do
        text = response_text(context.reply)

        assert text =~ "zai"
        assert text =~ "glm-cheap"

        {:ok, context}
      end
    end
  end
end
