defmodule CodeMySpecSpex.Story1057.Criterion2482Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 2482 — The machinery report shows the promotion queue: what it is
  gating, or why it cannot.

  Twice on 2026-10-25 the queue could not make its gate copy and sat refusing
  for over ten minutes. Every team's landing waited on it, and main found out
  by grepping a log. The queue is machinery the whole fleet depends on, so it
  belongs in the report main reads for machinery.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The promotion queue is part of the machinery report", criterion: 2482 do
    scenario "nothing is waiting to land" do
      given_ "a project with a checkout and an empty queue", context do
        reply = join_working_copy(context, "/tmp/spex-2482", "the checkout")

        {:ok,
         Map.put(context, :scope, %{context.scope | active_working_copy_id: reply.working_copy_id})}
      end

      when_ "the main agent looks at the machinery", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "check_machinery",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), inspect(response)
        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "the queue is reported, idle with nothing waiting", context do
        assert context.report =~ ~r/^queue: idle; nothing waiting/m,
               """
               The queue should be in the machinery report, saying plainly that
               it is idle, so that a quiet queue is a stated fact rather than an
               absence main has to interpret.

               report:
               #{context.report}
               """

        {:ok, context}
      end
    end
  end
end
