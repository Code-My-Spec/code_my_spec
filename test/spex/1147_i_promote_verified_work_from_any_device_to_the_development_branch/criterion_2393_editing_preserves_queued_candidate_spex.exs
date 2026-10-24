defmodule CodeMySpecSpex.Story1147.Criterion2393Spex do
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

  spex "John keeps editing while his verified candidate is queued", criterion: 2393 do
    scenario "John keeps editing while his verified candidate is queued" do
      given_ "a verified candidate", context do
        {:ok, context |> remote_project() |> verified_candidate() |> require_gate()}
      end

      when_ "John queues it and edits the source before the gate completes", context do
        context = context |> request_publication() |> await_gate()
        PromotionHelpers.write(context.agent_root, "lib/example.ex", "unsaved new work\n")
        PromotionHelpers.write(context.agent_root, "notes.txt", "keep this too\n")
        {:ok, outcome(context)}
      end

      then_ "only the queued candidate is published and the edits survive", context do
        published = remote_head(context)

        assert git!(context.origin, ["merge-base", "--is-ancestor", context.candidate, published]) ==
                 ""

        assert git!(context.origin, ["show", "#{published}:lib/example.ex"]) ==
                 git!(context.agent_root, ["show", "#{context.candidate}:lib/example.ex"])

        assert PromotionHelpers.read(context.agent_root, "lib/example.ex") == "unsaved new work\n"
        assert PromotionHelpers.read(context.agent_root, "notes.txt") == "keep this too\n"
        assert context.outcome =~ "published"
        {:ok, context}
      end
    end
  end
end
