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

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Every caller sees only its own open questions" do
    scenario "Durable-agent identity takes precedence over an external session on the same copy" do
      given_ "two external sessions and two internal agents share a user and project", context do
        first = given_a_staffed_checkout(context, "spex_2418_first")
        second = given_a_staffed_checkout(context, "spex_2418_second")

        external_callers =
          Enum.map([{first, "External first"}, {second, "External second"}], fn {copy, label} ->
            session_id = "spex-2418-#{System.unique_integer([:positive])}"

            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", copy.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.dispatch(
              CodeMySpecLocalWeb.Endpoint,
              :post,
              "/api/hooks/session-start",
              %{"session_id" => session_id}
            )
            |> Phoenix.ConnTest.json_response(200)

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

            {:reply, asked, _} =
              AskUserQuestion.execute(
                %{
                  questions: [
                    %{question: question, options: [%{label: "Keep it"}, %{label: "Change it"}]}
                  ]
                },
                caller.frame
              )

            refute asked.isError, response_text(asked)
            [_, id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
            Map.merge(caller, %{question: question, question_id: id})
          end)

        {:ok, Map.put(context, :callers, callers)}
      end

      when_ "all four callers list their open questions", context do
        listings =
          Enum.map(context.callers, fn caller ->
            {:reply, listed, _} = ListUserQuestions.execute(%{}, caller.frame)
            refute listed.isError, response_text(listed)
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
