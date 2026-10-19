defmodule CodeMySpecSpex.Story1127.Criterion2283Spex do
  @moduledoc """
  Story 1127 — An external agent's status comes from its own hooks.
  Criterion 2283 — A terminal coder's tokens per turn come from its session files.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp digest(context) do
    {:ok, work} = ToolLibrary.run("list_agent_work", %{}, %{scope: context.scope})
    work
  end

  defp hook(context, name, extra),
    do:
      HarnessHooks.post_hook(context, name, Map.merge(%{"session_id" => context.session}, extra))

  spex "A terminal coder's tokens per turn come from its session files", criterion: 2283 do
    scenario "the coder finishes a turn and John reads the performance report" do
      given_ "John's terminal coder finished a turn", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        transcript = transcript_for(session)

        started =
          start_session_on_socket(context, session, inbox.socket, transcript: transcript)

        assert {:ok, _} = set_role(context, session, "coding")
        look(started["agent_id"])

        context =
          Map.merge(context, %{
            inbox: inbox,
            session: session,
            transcript: transcript,
            agent_id: started["agent_id"]
          })

        hook(context, "user-prompt-submit", %{"prompt" => "Split the context."})
        eventually(fn -> assert digest(context) =~ "a turn opened" end)

        write_transcript(transcript, %{
          "type" => "assistant",
          "message" => %{
            "id" => "msg_1",
            "model" => "claude-opus-5-5",
            "usage" => %{"input_tokens" => 1000, "output_tokens" => 234},
            "content" => [%{"type" => "text", "text" => "Done."}]
          }
        })

        # The hook's own payload carries a figure; it is not usage the product reads.
        hook(context, "stop", %{"usage" => %{"input_tokens" => 99_999, "output_tokens" => 99_999}})

        {:ok, context}
      end

      when_ "John reads the agent performance report", context do
        {:ok, context}
      end

      then_ "the coder's tokens for that turn come from its engine's session files", context do
        eventually(fn ->
          {:ok, report} =
            ToolLibrary.run("agent_performance_report", %{"agent_id" => context.agent_id}, %{
              scope: context.scope
            })

          assert report =~ ~r/claude-code \|.*\| 1234 \|/
        end)

        {:ok, report} =
          ToolLibrary.run("agent_performance_report", %{"agent_id" => context.agent_id}, %{
            scope: context.scope
          })

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the hook events that drove its status recorded no usage of their own", context do
        refute context.report =~ "99999"
        refute context.report =~ "199998"
        {:ok, context}
      end
    end
  end
end
