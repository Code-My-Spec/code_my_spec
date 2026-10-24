defmodule CodeMySpecSpex.Story1147.Criterion2400Spex do
  @moduledoc "Story 1147: an offline preview applies the published revision when its own harness reconnects."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.{DeviceSyncHelpers, RemotePromotionHelpers}
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = CodeMySpecSpex.Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "John sees an offline preview catch up after promotion", criterion: 2400 do
    scenario "the preview reconnects after the remote publication completed" do
      given_ "a published story awaiting its offline preview", context do
        {:ok,
         context
         |> RemotePromotionHelpers.remote_project()
         |> DeviceSyncHelpers.offline_destination()
         |> RemotePromotionHelpers.verified_candidate()
         |> RemotePromotionHelpers.request_publication()
         |> RemotePromotionHelpers.outcome()}
      end

      when_ "the desktop harness reconnects and confirms the served revision", context do
        {:ok, context |> DeviceSyncHelpers.reconnect() |> DeviceSyncHelpers.serve_revision()}
      end

      then_ "the preview is applied without another promotion", context do
        assert DeviceSyncHelpers.await_status(context, "applied") =~
                 "device sync applied at #{context.candidate}"

        assert RemotePromotionHelpers.git!(context.destination_root, ["rev-parse", "HEAD"]) ==
                 context.candidate

        assert RemotePromotionHelpers.remote_head(context) == context.candidate
        {:ok, context}
      end
    end
  end
end
