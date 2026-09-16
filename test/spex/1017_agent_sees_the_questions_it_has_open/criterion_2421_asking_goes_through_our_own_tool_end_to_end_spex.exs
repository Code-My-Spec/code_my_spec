defmodule CodeMySpecSpex.Story1017.Criterion2421Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2421 — Asking goes through our own tool end to end.

  The rule:

  > The agent asks with our tool, and nothing has to be taken away from it for
  > that to work.

  ## Why the second half is the interesting half

  Recording a question and handing back its id is the easy claim, and the rest
  of this story leans on it — every other criterion starts from "the agent asked
  a question". This one establishes it rather than assuming it.

  The clause that earns the criterion is the other one. Claude Code ships its own
  `AskUserQuestion`, and the obvious way to make questions land in our database
  is to deny that tool in `PreToolUse` and push the agent onto ours. It works,
  and it is a trap: a denial is a refusal the agent reads mid-turn, so the agent
  is taught that asking is something that gets blocked, and every future reader
  of the hook has to know that one denial is load-bearing rather than a rule
  about safety. `PreToolUse` already denies things for real reasons — `git`
  writes, some `Bash` — and burying a routing decision among them is how a
  safety rule becomes indistinguishable from plumbing.

  So the claim is that our tool stands on its own: it is offered, the agent
  calls it, and Claude's own stays untouched.

  ## What it observes

  Both halves at the surfaces that own them — `ask_user_question` as an MCP tool
  for the recording, and the `PreToolUse` hook itself for the denial. Asserted
  against the hook rather than by reading `pre_tool_use.ex` for the absence of a
  clause, because absence in source is what a grep proves and a decision is what
  an agent meets.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions

  @question "Which approach do you want here?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent asks with our tool, and nothing is taken away for it to work" do
    scenario "the agent asks a question through the MCP tool" do
      given_ "a session exists for this working copy", context do
        session_id = "spex-2421-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(
          CodeMySpecLocalWeb.Endpoint,
          :post,
          "/api/hooks/session-start",
          %{"session_id" => session_id}
        )
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent asks the user a question through the MCP tool", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: @question,
                  header: "Approach",
                  multiSelect: false,
                  options: [
                    %{label: "The first one", description: "keep the existing shape"},
                    %{label: "The second one", description: "rewrite it"}
                  ]
                }
              ]
            },
            frame
          )

        refute response.isError,
               "asking is the agent's own surface and has to work. Got: #{response_text(response)}"

        {:ok, Map.put(context, :asked, response_text(response))}
      end

      then_ "the agent is given the question's id", context do
        assert context.asked =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/,
               """
               The agent asked and was told nothing it can hold on to.

               An id is what makes the question addressable afterwards — it is
               how `check_answer` collects the reply. Without one the agent has
               asked into the dark and can only poll the whole list.

               Got: #{context.asked}
               """

        {:ok, context}
      end

      then_ "and the question is recorded", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListUserQuestions.execute(%{}, frame)
        text = response_text(response)

        assert text =~ @question,
               """
               The tool answered but the question is not on the agent's own list.

               Everything else on this story starts from a question being open,
               so a tool that reports success without recording one makes the
               rest of it vacuous.

               Got:\n#{text}
               """

        {:ok, context}
      end

      then_ "and no hook had to deny Claude's own AskUserQuestion", context do
        decision =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(
            CodeMySpecLocalWeb.Endpoint,
            :post,
            "/api/hooks/pre-tool-use",
            %{
              "session_id" => context.session_id,
              "tool_name" => "AskUserQuestion",
              "tool_input" => %{"questions" => [%{"question" => @question}]}
            }
          )
          |> Phoenix.ConnTest.json_response(200)
          |> get_in(["hookSpecificOutput", "permissionDecision"])

        refute decision == "deny",
               """
               Claude's own `AskUserQuestion` is denied, which means our tool is
               being reached by taking the alternative away rather than by being
               the better one.

               A denial is a refusal the agent reads mid-turn: it learns that
               asking is a thing that gets blocked. And `PreToolUse` denies real
               things for real reasons — `git` writes, some `Bash` — so a routing
               decision parked among them stops anyone being able to tell a
               safety rule from plumbing.

               permissionDecision: #{inspect(decision)}
               """

        {:ok, context}
      end
    end
  end
end
