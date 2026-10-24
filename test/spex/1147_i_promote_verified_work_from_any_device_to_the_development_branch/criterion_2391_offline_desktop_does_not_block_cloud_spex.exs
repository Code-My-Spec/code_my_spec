defmodule CodeMySpecSpex.Story1147.Criterion2391Spex do
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.RemotePromotionHelpers
  import CodeMySpecSpex.DeviceSyncHelpers
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "John integrates cloud work while the desktop is offline", criterion: 2391 do
    scenario "the source device supplies the candidate and the gate" do
      given_ "a source candidate and an offline desktop destination", context do
        {:ok, context |> remote_project() |> offline_destination() |> verified_candidate()}
      end

      when_ "John promotes from the source", context do
        {:ok, context |> request_publication() |> outcome()}
      end

      then_ "the remote advances while the offline desktop remains at its old revision",
            context do
        assert remote_head(context) == context.candidate
        assert git!(context.destination_root, ["rev-parse", "HEAD"]) == context.base
        assert context.outcome =~ "published"
        {:ok, context}
      end
    end
  end
end
