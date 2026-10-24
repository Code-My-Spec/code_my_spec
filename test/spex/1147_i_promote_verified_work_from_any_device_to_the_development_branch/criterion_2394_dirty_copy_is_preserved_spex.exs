defmodule CodeMySpecSpex.Story1147.Criterion2394Spex do
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.RemotePromotionHelpers
  alias CodeMySpecSpex.{Fixtures, PromotionHelpers}
  alias Ecto.Adapters.SQL.Sandbox
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "John sees a dirty copy refused without losing files", criterion: 2394 do
    scenario "John sees a dirty copy refused without losing files" do
      given_ "a verified candidate with additional unsaved work", context do
        context = context |> remote_project() |> verified_candidate()
        PromotionHelpers.write(context.agent_root, "lib/example.ex", "unsaved\n")
        {:ok, context}
      end

      when_ "John asks to promote", context do
        {:ok,
         Map.put(context, :response, PromotionHelpers.promote(context, context.story.number))}
      end

      then_ "nothing is published and the edit remains", context do
        assert context.response.isError
        assert remote_head(context) == context.base
        assert PromotionHelpers.read(context.agent_root, "lib/example.ex") == "unsaved\n"
        {:ok, context}
      end
    end
  end
end
