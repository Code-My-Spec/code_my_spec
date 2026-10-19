defmodule CodeMySpecSpex.Story1124.Criterion2251Spex do
  @moduledoc """
  Story 1124 — A terminal agent's state reads like any agent's.
  Criterion 2251 — A terminal agent's conversation and usage come from its transcript.
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

  spex "A terminal agent's conversation and usage come from its transcript", criterion: 2251 do
    scenario "a terminal agent works a turn and its transcript records it" do
      given_ "a terminal agent with a session transcript", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        transcript = transcript_for(session)

        started =
          start_session_on_socket(context, session, inbox.socket, transcript: transcript)

        {:ok,
         Map.merge(context, %{
           session: session,
           transcript: transcript,
           agent_id: started["agent_id"]
         })}
      end

      when_ "the session works a turn and writes it to its transcript", context do
        submit_prompt(context, context.session)
        eventually(fn -> assert digest(context) =~ "has not finished" end)

        write_transcript(
          context.transcript,
          %{
            "type" => "assistant",
            "message" => %{
              "id" => "msg_1",
              "model" => "claude-opus-5-5",
              "usage" => %{"input_tokens" => 1200, "output_tokens" => 340},
              "content" => [%{"type" => "text", "text" => "Splitting the reservations context."}]
            }
          }
        )

        stop_turn(context, context.session)
        {:ok, context}
      end

      then_ "its conversation shows what the transcript says it said", context do
        eventually(fn ->
          {:ok, said} =
            ToolLibrary.run("read_agent_conversation", %{"agent_id" => context.agent_id}, %{
              scope: context.scope
            })

          assert said =~ "Splitting the reservations context."
        end)

        {:ok, context}
      end

      then_ "its usage is what the transcript says the turn spent", context do
        eventually(fn ->
          {:ok, report} =
            ToolLibrary.run("agent_performance_report", %{"agent_id" => context.agent_id}, %{
              scope: context.scope
            })

          # 1,200 in and 340 out, as the transcript's turn recorded them.
          assert report =~ ~r/claude-code \|.*\| 1540 \|/
        end)

        {:ok, context}
      end
    end
  end
end
