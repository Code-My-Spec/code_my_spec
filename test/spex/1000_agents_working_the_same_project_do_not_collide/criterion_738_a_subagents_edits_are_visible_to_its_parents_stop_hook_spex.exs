defmodule CodeMySpecSpex.Story1000.Criterion738Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 738 — A subagent's edits are visible to its parent's stop hook.

  Rule: A subagent works inside its parent's agent.

  A subagent is not a second agent. It shares the parent's working copy, so its
  edits are the parent's checkout changing — and the parent's stop hook has to
  evaluate them as its own. Treating a subagent as its own agent would give the
  parent a file state describing a tree that its own subagent has already moved
  past.

  This is the exact seam that broke in production: `SubagentStop` called
  `Validation.validate_stop/2`, dropping the opts that carry the session id, so
  attribution came back nil and every subagent stop reported "attribution is
  unavailable" and blocked on every finding in the project. Fixed in `7b0504a0`;
  this pins the property so it cannot silently regress.

  Surfaces: the hook endpoint and the channel. The subagent's edit arrives
  through PostToolUse under its own `agent_id`, and the same working copy — one
  harness, because a subagent is not a second one — reports the changed tree.
  The parent's stop hook is where both have to land.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version 1
  @path "lib/written_by_the_subagent.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A subagent is inside its parent, not beside it" do
    scenario "A subagent's edits are visible to its parent's stop hook" do
      given_ "an agent has started a subagent in the same working copy", context do
        # Same working copy, same harness. Only `agent_id` distinguishes them,
        # which is the whole claim: the subagent is a lane inside this agent, not
        # a second one.
        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_parent", %{scope: context.scope})
          |> subscribe_and_join(
            HarnessProjectChannel,
            "harness_project:#{context.project.id}",
            %{
              "contract_version" => @contract_version,
              "harness_id" => context.scope.active_harness_id,
              "root" => context.scope.cwd,
              "label" => "the harness the parent and its subagent share"
            }
          )

        {:ok,
         context
         |> Map.put(:agent, socket)
         |> Map.put(:working_copies_before, working_copies(context))
         |> Map.put(:parent_session, "spex-parent-#{System.unique_integer([:positive])}")
         |> Map.put(:subagent_id, "a-sub-#{System.unique_integer([:positive])}")}
      end

      when_ "the subagent edits a file", context do
        :ok =
          Environments.write_file(
            context.environment,
            @path,
            "defmodule WrittenByTheSubagent do\n  @moduledoc false\nend\n"
          )

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(
          CodeMySpecLocalWeb.Endpoint,
          :post,
          "/api/hooks/post-tool-use",
          %{
            "session_id" => context.parent_session,
            "agent_id" => context.subagent_id,
            "tool_name" => "Write",
            "tool_input" => %{"file_path" => Path.join(context.scope.cwd, @path)}
          }
        )

        # The working copy reporting what it now contains. One harness sends it,
        # because there is one checkout — the subagent did not get its own.
        ref =
          Phoenix.ChannelTest.push(context.agent, "observations", %{
            "observations" => [
              %{
                "path" => @path,
                "role" => "implementation",
                "fingerprint" => "by-the-subagent",
                "mtime" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            ]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 1000)

        {:ok, context}
      end

      then_ "the edit appears in the parent agent's files", context do
        {:ok, _files_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        assert working_copies(context) == context.working_copies_before,
               "a subagent's edit minted a second working copy — the operator's picker now " <>
                 "offers one checkout twice. A subagent shares its parent's tree, so a second " <>
                 "agent here means two file states for one directory."

        assert html =~ "written_by_the_subagent.ex",
               "a subagent's edit did not reach the working copy's file state. The parent " <>
                 "now has a file state describing a tree its own subagent has moved past."

        {:ok, context}
      end

      then_ "the parent's stop hook evaluates that change as its own", context do
        stop =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(
            CodeMySpecLocalWeb.Endpoint,
            :post,
            "/api/hooks/stop",
            %{"session_id" => context.parent_session}
          )
          |> Phoenix.ConnTest.json_response(200)

        # The regression this guards: attribution coming back unavailable, which
        # renders as a block on every finding in the project rather than on the
        # parent's own work. `SubagentStop` dropped the opts carrying the session
        # id, so `session_paths/2` answered nil on every subagent stop that has
        # ever run (`7b0504a0`).
        refute (stop["reason"] || "") =~ "ttribution is unavailable",
               "the parent's stop hook could not attribute its own subagent's edit, so it " <>
                 "blocks on every finding in the project — including other agents' stories. " <>
                 "This is the `7b0504a0` regression. Got: #{inspect(stop)}"

        {:ok, context}
      end
    end
  end

  # Counted off the operator's harness picker rather than out of the database:
  # the picker is where a phantom working copy would actually be seen, and the
  # spex boundary does not reach `CodeMySpec.Harnesses` — correctly, since a
  # spec asserting on rows nobody renders proves nothing about the product.
  defp working_copies(context) do
    {:ok, _live, html} = live(context.conn, "/app/projects/#{context.project.id}/files")

    html
    |> String.split(~s(data-test="harness-))
    |> length()
    |> Kernel.-(1)
  end
end
