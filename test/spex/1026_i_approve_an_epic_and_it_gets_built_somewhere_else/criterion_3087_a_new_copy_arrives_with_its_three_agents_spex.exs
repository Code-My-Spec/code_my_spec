defmodule CodeMySpecSpex.Story964.Criterion3087Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 3087 — A new copy arrives with its three agents.

  Rule: A working copy comes up with its three agents, and the same three serve
  every epic it is given.

  John, 2026-09-04, describing the shape he is building toward: *"when we come
  up with a working copy the three agents are there, and if that working copy is
  assigned more work it's gonna be the same three agents ... I want my three sub
  agents to start up in there. Essentially, those are gonna be the guys who are
  gonna be taking work off of the graph."*

  So the agents belong to the **copy**, not to the epic. The roles already
  exist — `Agent`'s `@roles` is `[:main, :product, :coding, :qa]`, which is the
  main agent plus exactly these three — and nothing starts them. `:product` and
  `:coding` appear nowhere outside the enum; `:qa` appears only as a subagent
  dispatched inside a task, never as a standing agent on a copy.

  ## Red on purpose

  This describes work that has not been done. `EpicDispatch.approve/2` sets a
  status and a `working_copy_id` and returns — grepping `:dispatched` finds the
  LiveView, the requirement checker and the schema, and no starter. Criterion
  2930's moduledoc records that discovery and narrowed itself to stop claiming
  an agent it could not produce (issue 28e838cc). This is the criterion that
  claims it, so it fails until something starts them.

  Safe to leave red, which it would not have been this morning: a red spex only
  blocked on a story whose `specs_ready` latch was set, and adding a criterion
  did not clear it — so new criteria written red blocked every other session in
  the project (issue 10e86fa2). Adding a criterion now restarts the chain.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A working copy comes up with its three agents" do
    scenario "A new copy arrives with its three agents" do
      given_ :synced_context_component

      given_ "an epic I have agreed to build", context do
        {:ok, EpicHelpers.dispatch_one(context, "The war epic", stories: 2)}
      end

      when_ "I look at the copy it was placed on", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "its product, coding and QA agents are on it", context do
        for role <- ~w(product coding qa) do
          assert context.html =~ ~s(data-agent-role="#{role}"),
                 "the copy came up without a #{role} agent. The roles exist in " <>
                   "`Agent`'s enum and nothing starts them, so a copy that was " <>
                   "given an epic has nobody on it to do the work. Got: " <>
                   String.slice(context.html, 0, 400)
        end

        {:ok, context}
      end

      then_ "I can reach each of them from that copy's conversation", context do
        assert context.html =~ ~s(data-test="open-agent-chat"),
               "the agents are listed and there is no way to talk to any of them. " <>
                 "A roster I cannot address is a status display, not a team."

        {:ok, context}
      end
    end
  end
end
