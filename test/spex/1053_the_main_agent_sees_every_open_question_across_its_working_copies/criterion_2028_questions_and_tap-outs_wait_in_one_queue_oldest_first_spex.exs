defmodule CodeMySpecSpex.Story1053.Criterion2028Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question across its working
  copies.
  Criterion 2028 — Questions and tap-outs wait in one queue, oldest first.
  Title only; no scenario was recorded.

  A question (`ask_user_question`) and a tap-out are two different request
  types underneath — `OpenQuestion.new/3` and `OpenQuestion.from_permission/4`
  build the same struct from different tables (criterion 1233's own doc:
  "a `tap_out` or an `ask_user_question` is an agent waiting on a person
  exactly as a question is"). `listing/2` groups both by `holder` into
  sections, so two entries only share a queue in any order-testable sense
  once they share a *holder* — otherwise "which section comes first" is a
  presentation choice, not the ordering this criterion names. Both land on
  `main_agent` here: the tap-out via aging (criterion 1980/1991), the
  question because it is coding's own (`RoleProfile.questions_to(:coding)`).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Main.Cadence
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question and a tap-out share one queue, ordered by when each was raised",
       criterion: 2028 do
    scenario "an aged tap-out, raised first, comes back before a question raised after it" do
      given_ "a coding agent's tap-out aged past one recovery interval", context do
        reply = join_working_copy(context, "/tmp/spex-2028", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        tapper = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2028")
        tapper_frame = %Frame{assigns: %{current_scope: scope, agent_id: tapper.id}}

        {:reply, tapped, _} =
          TapOut.execute(
            %{reason: "this task's work should not exist — the component was already removed"},
            tapper_frame
          )

        refute tapped.isError, response_text(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))

        :ok =
          Fixtures.age_permission(scope, permission_id, Cadence.interval(scope) + 60)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:permission_id, permission_id)}
      end

      given_ "a second coding agent's question, raised after the tap-out", context do
        asker = Fixtures.running_agent(context.scope, role: "coding", working_copy: "/tmp/spex-2028")
        asker_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: asker.id}}

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  "question" => "Which registrar owns this domain?",
                  "options" => [%{"label" => "ours"}, %{"label" => "a client's"}]
                }
              ]
            },
            asker_frame
          )

        refute asked.isError, response_text(asked)

        {:ok, Map.put(context, :question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent looks at what is waiting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, inbox, _} = ListNotifications.execute(%{}, frame)
        refute inbox.isError, response_text(inbox)
        {:ok, Map.put(context, :listing, response_text(inbox))}
      end

      then_ "both are in the same (main agent's own) section", context do
        assert context.listing =~ context.permission_id and
                 context.listing =~ context.question_id,
               """
               The aged tap-out and the question must both be the main agent's own
               to settle before their relative order can mean anything.

               listing:
               #{context.listing}
               """

        {:ok, context}
      end

      then_ "the tap-out (raised first) comes before the question (raised after it)", context do
        {tapout_pos, _} = :binary.match(context.listing, context.permission_id)
        {question_pos, _} = :binary.match(context.listing, context.question_id)

        assert tapout_pos < question_pos,
               """
               The tap-out, raised first, does not come before the question raised
               after it — questions and tap-outs are not sharing one oldest-first
               queue.

               listing:
               #{context.listing}
               """

        {:ok, context}
      end
    end
  end
end
