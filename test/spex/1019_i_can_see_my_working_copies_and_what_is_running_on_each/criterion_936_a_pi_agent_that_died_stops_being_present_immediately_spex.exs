defmodule CodeMySpecSpex.Story1019.Criterion2831Spex do
  @moduledoc """
  Story 1019 — I can see my working copies and what is running on each.
  Criterion 2831 — A Pi agent that died stops being present immediately.

  Rule: Liveness is shown for what it is: a Pi agent is present or not, a Claude
  Code agent was last heard from at a time.

  The half of the rule that earns the word "present". Presence is not a note
  saying an agent is alive; it is the process being joined. When the process
  goes, the join goes, and so does the fact — with nothing to expire and no
  sweep to wait for.

  This is the property story 704 bought when it replaced a polled subagent-TTL
  registry with Presence, and the property story 1018 lost and rebuilt when it
  grew a `Device` behaviour with a fake that could drift on purpose. A liveness
  record kept by hand always drifts; the drift is invisible; and the page is the
  place where the drift becomes a lie somebody acts on.

  Driven through the harness reporting what it is running, which is where the
  absence enters the system. Nothing simulates a death — the next report simply
  does not mention it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Presence goes when the process does", criterion: 936 do
    scenario "A Pi agent that died stops being present immediately" do
      given_ "a Pi agent shown as present on a copy", context do
        {dying, socket} =
          join_working_copy_socket(context, "/tmp/spex-1019-dying", "dying checkout")

        id =
          context
          |> report_agents([pi_agent(dying.working_copy_id, "/tmp/spex-1019-dying")])
          |> reported_id("/tmp/spex-1019-dying")

        :ok = agent_up(socket, id)

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert render(live) =~ ~r/running/i,
               "the agent has to be present before its going away means anything"

        {:ok, Map.merge(context, %{live: live, socket: socket, agent_id: id})}
      end

      when_ "its process goes away", context do
        # The copy's harness says so the moment its process exits.
        :ok = agent_down(context.socket, context.agent_id)

        {:ok, context}
      end

      then_ "it stops reading as running, without anyone refreshing anything",
            context do
        # Presence broadcasts the change; the page re-renders when it arrives.
        eventually(fn ->
          row =
            context.live
            |> element("[data-test='working-copy'][data-root='/tmp/spex-1019-dying']")
            |> render()

          refute row =~ ~r/\brunning\b/i,
                 "the agent is gone and the page still says running. Nothing here " <>
                   "should have to expire first: presence is the process being " <>
                   "joined, so losing the process is losing the fact. A row that " <>
                   "outlives its agent is how somebody assigns work to nothing. " <>
                   "Got: #{row}"
        end)

        {:ok, context}
      end

      then_ "and the copy itself is still listed", context do
        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-root='/tmp/spex-1019-dying']"
               ),
               "the copy disappeared along with its agent. The checkout still " <>
                 "exists — it is the agent that went — and dropping the row " <>
                 "answers 'what is busy' instead of 'what have I got'."

        {:ok, context}
      end
    end
  end
end
