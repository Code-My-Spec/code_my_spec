defmodule CodeMySpecSpex.Story1147.Criterion2392Spex do
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.RemotePromotionHelpers
  import Phoenix.ChannelTest, only: [close: 1]
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpecSpex.{Fixtures, PromotionHelpers}
  alias Ecto.Adapters.SQL.Sandbox
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "John retries safely after his source device disconnects", criterion: 2392 do
    scenario "an unavailable source cannot create a false publication" do
      given_ "a reviewed candidate whose source harness disconnects", context do
        context = context |> remote_project() |> verified_candidate()
        Process.unlink(context.agent_socket.channel_pid)
        close(context.agent_socket)

        Fixtures.put_fixture_execution_context(
          context.scope,
          ExecutionContext.new(:harness, context.agent_root)
        )

        {:ok, context}
      end

      when_ "John requests promotion while it is unavailable", context do
        {:ok,
         Map.put(context, :response, PromotionHelpers.promote(context, context.story.number))}
      end

      then_ "the refusal reports the unavailable machine without advancing origin", context do
        assert context.response.isError
        text = CodeMySpecSpex.TaskResponseHelpers.response_text(context.response)
        assert text =~ "could not reach"
        assert remote_head(context) == context.base
        {:ok, context}
      end

      when_ "the source reconnects and John retries", context do
        {_, socket} =
          PromotionHelpers.join_local_working_copy_socket(
            context,
            context.agent_root,
            "cloud source",
            working_copy_id: context.agent.working_copy_id,
            device_id: context.agent.device_id
          )

        {:ok, context |> Map.put(:agent_socket, socket) |> request_publication() |> outcome()}
      end

      then_ "the same reviewed candidate is published", context do
        assert remote_head(context) == context.candidate
        assert context.outcome =~ "published"
        {:ok, context}
      end
    end
  end
end
