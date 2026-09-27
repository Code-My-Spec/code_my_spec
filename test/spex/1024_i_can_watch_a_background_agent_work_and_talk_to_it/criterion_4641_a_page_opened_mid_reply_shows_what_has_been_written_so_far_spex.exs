defmodule CodeMySpecSpex.Story1024.Criterion4641Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 4641 — A page opened mid-reply shows what has been written so far.

  Rule: An agent's reply appears as it is written, and becomes the message when
  it is done.

  The durable half of drafting. A draft only broadcast is gone for anyone who
  was not already watching — a reload, a reconnect, an operator arriving late —
  until the model writes its next word, which while the provider holds the
  reply is never. The page opened here arrives after every draft was sent.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.RealDisk
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A reply in progress is there for whoever opens the page" do
    scenario "A page opened mid-reply shows what has been written so far" do
      given_ "an agent part-way through a reply", context do
        copy = CodeMySpec.TempFile.dir("spex_4641")
        RealDisk.mkdir_p!(copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_4641", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        context = agent_on_held_provider(context, socket, copy)

        # Someone else's page, used to ask the message and to know the draft has
        # landed before the page under test is opened — otherwise "opened
        # mid-reply" is a race with the draft still on its way.
        {:ok, watcher, _html} = live(context.conn, context.conversation_path)
        :ok = reply_part_way(Map.put(context, :live, watcher))

        eventually(fn ->
          assert has_element?(watcher, "#agent-writing", HeldProvider.reply_so_far()),
                 "the premise is a reply the server already has part of"
        end)

        {:ok, context}
      end

      when_ "I open its conversation", context do
        {:ok, live, _html} = live(context.conn, context.conversation_path)
        {:ok, Map.put(context, :live, live)}
      end

      then_ "the page shows what it has written so far without waiting for more", context do
        assert has_element?(context.live, "#agent-writing", HeldProvider.reply_so_far()),
               "a page opened mid-reply shows nothing of it until the model writes " <>
                 "again — the draft existed only for pages that were already open"

        HeldProvider.release()
        await_quiet(context)
        {:ok, context}
      end
    end
  end
end
