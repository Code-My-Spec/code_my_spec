defmodule CodeMySpecSpex.Story1000.Criterion741Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 741 — A human editing inside an agent's workspace is attributed to that agent.

  Rule: Only work in an agent's workspace is tracked.

  The other side of criterion 740. There, an edit in an unserved copy is nobody's
  and must not be recorded. Here, an edit in a served copy is *that agent's*, even
  though no agent made it — because the agent is the working copy, not the
  process. An operator fixing a typo by hand has changed what that checkout
  contains, and the next stop hook has to evaluate the tree as it now is.

  Attributing by working copy rather than by author is what makes that work. The
  alternative — tracking only edits an agent's own tools made — would leave the
  agent's file state describing a tree that no longer exists, and its analyzers
  reporting on code that is not there.

  Surfaces, both of them, because "by hand" is what makes this criterion
  different from every other one about file state.

  A hand edit fires **no hook**. Nobody called Write, so no PostToolUse records
  it, and any spec that posts one to stand in for the operator is asserting
  against an agent's edit wearing an operator's name. The only thing that sees a
  hand edit is the harness watching the working copy — so the channel is the
  `when_`, and the stop hook is where the consequence has to show up.

  Which is exactly where the risk lives: attribution narrows a stop's blocking
  set to files the session recorded through PostToolUse, and a hand edit has no
  such record. If that narrowing were the only rule, the operator's change would
  be invisible to the gate.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version 1
  @path "lib/typo_fixed_by_hand.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The working copy is the unit, not the author" do
    scenario "A human editing inside an agent's workspace is attributed to that agent" do
      given_ "an agent is serving a working copy", context do
        # Joining with the scope's own harness id, so the agent serving this
        # checkout and the agent the assertions read back are the same one.
        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_served", %{scope: context.scope})
          |> subscribe_and_join(
            HarnessProjectChannel,
            "harness_project:#{context.project.id}",
            %{
              "contract_version" => @contract_version,
              "harness_id" => context.scope.active_harness_id,
              "root" => context.scope.cwd,
              "label" => "the harness serving #{context.scope.cwd}"
            }
          )

        {:ok, Map.put(context, :agent, socket)}
      end

      when_ "the operator edits a file in it by hand", context do
        # Straight into the working copy. No tool call, so no PostToolUse — that
        # absence is the premise, not an omission.
        :ok =
          Environments.write_file(
            context.environment,
            @path,
            "defmodule TypoFixedByHand do\n  @moduledoc false\nend\n"
          )

        # What a hand edit does produce: the harness notices the tree changed and
        # says so. This is the only report the operator's edit generates.
        ref =
          Phoenix.ChannelTest.push(context.agent, "observations", %{
            "observations" => [
              %{
                "path" => @path,
                "role" => "implementation",
                "fingerprint" => "edited-by-hand",
                "mtime" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            ]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 1000)

        {:ok, context}
      end

      then_ "the change is recorded against that agent", context do
        {:ok, _files_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        assert html =~ "typo_fixed_by_hand.ex",
               "an edit made by hand inside a served working copy was not recorded against " <>
                 "the agent serving it. The agent's file state now describes a tree that no " <>
                 "longer exists, and its analyzers will report on code that is not there."

        {:ok, context}
      end

      then_ "that agent's stop hook evaluates it like any other change", context do
        stop =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(
            CodeMySpecLocalWeb.Endpoint,
            :post,
            "/api/hooks/stop",
            %{"session_id" => "spex-operator-edit"}
          )
          |> Phoenix.ConnTest.json_response(200)

        # "Like any other change" means the analyzers were pointed at it. The
        # stop hook says so by name when it enqueues, and says nothing about
        # analysis when it decided the tree was unchanged — which is the outcome
        # this criterion forbids, and the one a session-only attribution rule
        # would produce, since this session recorded no edits at all.
        rendered = inspect(stop)

        assert rendered =~ "analysis",
               "the stop hook ran no analysis over a working copy the operator had just " <>
                 "changed. An edit nobody's tool made is still that checkout's, and a gate " <>
                 "that only sees its own writes passes an agent over a tree it has not " <>
                 "looked at. Got: #{rendered}"

        {:ok, context}
      end
    end
  end
end
