defmodule CodeMySpecSpex.Story1017.Criterion2418Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2418 — Question visibility respects agent and session ownership.

  Four callers share one user and project. Two durable agents share a checkout
  with an external session; a second external session uses another checkout.
  Each asks through MCP. Listing must use the caller's identity, not user,
  project, role, or an internal agent's incidental external-session fallback.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Every caller sees only its own open questions", criterion: 911 do
    scenario "Durable-agent identity takes precedence over an external session on the same copy" do
      given_ "two external sessions and two internal agents share a user and project", context do
        # Two checkouts of the project, each served by its own live harness.
        first = HarnessHooks.ensure_live_harness(context)
        second = HarnessHooks.given_a_live_harness(context, files: %{"mix.exs" => "# second\n"})

        external_callers =
          Enum.map([{first, "External first"}, {second, "External second"}], fn {copy, label} ->
            session_id = "spex-2418-#{System.unique_integer([:positive])}"

            HarnessHooks.post_hook(copy, "session-start", %{"session_id" => session_id})

            %{label: label, frame: %Frame{assigns: %{current_scope: copy.scope}}}
          end)

        internal_callers =
          Enum.map([{"coding", "Internal coding"}, {"qa", "Internal QA"}], fn {role, label} ->
            agent = Fixtures.running_agent(first.scope, role: role, continuous: false)

            %{
              label: label,
              frame: %Frame{assigns: %{current_scope: first.scope, agent_id: agent.id}}
            }
          end)

        {:ok, Map.put(context, :callers, internal_callers ++ external_callers)}
      end

      given_ "every caller has asked a distinct question through the existing tool", context do
        callers =
          Enum.map(context.callers, fn caller ->
            question = "#{caller.label}: which behavior should I implement?"

            asked =
              ToolLibrary.run(
                "ask_question",
                %{
                  questions: [
                    %{question: question, options: [%{label: "Keep it"}, %{label: "Change it"}]}
                  ]
                },
                Map.put(caller.frame.assigns, :scope, caller.frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, asked), response_text(asked)
            [_, id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
            Map.merge(caller, %{question: question, question_id: id})
          end)

        {:ok, Map.put(context, :callers, callers)}
      end

      when_ "all four callers list their open questions", context do
        listings =
          Enum.map(context.callers, fn caller ->
            listed =
              ToolLibrary.run(
                "list_user_questions",
                %{},
                Map.put(caller.frame.assigns, :scope, caller.frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, listed), response_text(listed)
            Map.put(caller, :listing, response_text(listed))
          end)

        {:ok, Map.put(context, :listings, listings)}
      end

      then_ "each listing contains its own question and excludes all three other owners",
            context do
        Enum.each(context.listings, fn caller ->
          assert caller.listing =~ "1 open question", caller.label <> ": " <> caller.listing
          assert caller.listing =~ caller.question_id, caller.label <> ": " <> caller.listing
          assert caller.listing =~ caller.question

          context.callers
          |> Enum.reject(&(&1.question_id == caller.question_id))
          |> Enum.each(fn other ->
            refute caller.listing =~ other.question_id
            refute caller.listing =~ other.question
          end)
        end)

        {:ok, context}
      end
    end
  end
end
