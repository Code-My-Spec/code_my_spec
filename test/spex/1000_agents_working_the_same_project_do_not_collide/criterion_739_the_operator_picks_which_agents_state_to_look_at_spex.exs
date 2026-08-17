defmodule CodeMySpecSpex.Story1000.Criterion739Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 739 — The operator picks which agent's state to look at.

  Rule: The operator can see any agent's view, and sees the most recently active
  one by default.

  Once files and problems are per-agent, "the project's files" stops being a
  question with one answer, and the page has to say whose it is showing. The
  default matters as much as the switch: an operator who opened the project after
  an agent just ran expects to see that run, and a page that silently showed a
  different checkout's state would be lying in the most convincing way — with
  real data from the wrong tree.

  Surface: the cloud LiveView, because this criterion is about what an operator
  sees, not about what an agent is told.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version 1

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Whose state the project page is showing" do
    scenario "The operator picks which agent's state to look at" do
      given_ "two agents are serving the same project and both have synced", context do
        {older_id, _older} =
          join_and_sync(context, "/workspace/older", "lib/only_in_older.ex", "older")

        # Second, so it is the most recently active.
        {newer_id, _newer} =
          join_and_sync(context, "/workspace/newer", "lib/only_in_newer.ex", "newer")

        {:ok, context |> Map.put(:older_id, older_id) |> Map.put(:newer_id, newer_id)}
      end

      when_ "the operator opens the project", context do
        {:ok, files_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        {:ok, context |> Map.put(:files_live, files_live) |> Map.put(:html, html)}
      end

      then_ "the most recently active agent's state is shown", context do
        assert context.html =~ "only_in_newer.ex",
               "the project page did not show the most recently active agent's files. An " <>
                 "operator who just watched an agent run expects that run. Got a page " <>
                 "without it."

        refute context.html =~ "only_in_older.ex",
               "the page showed two agents' files at once, which is the collision this " <>
                 "story exists to end: real data from two trees, presented as one."

        {:ok, context}
      end

      then_ "the operator can switch to the other agent and see its files and problems instead",
            context do
        html =
          context.files_live
          |> element("[data-test='harness-picker'] [data-test='harness-#{context.older_id}']")
          |> render_click()

        assert html =~ "only_in_older.ex",
               "switching to the other agent did not show its files"

        refute html =~ "only_in_newer.ex",
               "after switching, the page still showed the previous agent's files"

        {:ok, context}
      end
    end
  end

  defp join_and_sync(context, root, path, fingerprint) do
    {:ok, reply, socket} =
      UserSocket
      |> socket("harness_#{fingerprint}", %{scope: context.scope})
      |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
        "contract_version" => @contract_version,
        "harness_id" => nil,
        "root" => root,
        "label" => "the harness at #{root}"
      })

    ref =
      Phoenix.ChannelTest.push(socket, "observations", %{
        "observations" => [
          %{
            "path" => path,
            "role" => "implementation",
            "fingerprint" => fingerprint,
            "mtime" => "2026-08-12T00:00:00.000000Z"
          }
        ]
      })

    Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 1000)

    {reply["harness_id"] || reply[:harness_id], socket}
  end
end
