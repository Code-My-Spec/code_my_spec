defmodule CodeMySpecSpex.Story1024.Criterion4639Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 4639 — The agent has written part of a reply; the page shows it
  before the turn ends.

  Rule: An agent's reply appears as it is written, and becomes the message when
  it is done.

  A real turn against a provider held part-way through its reply: the engine's
  text deltas, the harness's draft buffer, the channel, the draft store and the
  page, with only the socket stood in for.
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

  spex "An agent's reply appears as it is written", criterion: 1518 do
    scenario "The agent has written part of a reply; the page shows it before the turn ends" do
      given_ "an agent I am watching", context do
        copy = CodeMySpec.TempFile.dir("spex_4639")
        RealDisk.mkdir_p!(copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_4639", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        context = agent_on_held_provider(context, socket, copy)
        {:ok, live, _html} = live(context.conn, context.conversation_path)

        {:ok, Map.put(context, :live, live)}
      end

      when_ "it has written part of its reply", context do
        :ok = reply_part_way(context)
        {:ok, context}
      end

      then_ "the page shows what it has written so far", context do
        # `has_element?`, not `element/2`: a missing element raises, and
        # `eventually` retries only a failed assertion.
        eventually(fn ->
          assert has_element?(context.live, "#agent-writing", HeldProvider.reply_so_far()),
                 "the agent has written half its reply and the page shows none of it. " <>
                   "Watching that waits for the whole reply is watching a spinner."
        end)

        {:ok, context}
      end

      then_ "and the turn has not ended", context do
        refute render(context.live) =~ HeldProvider.whole_reply(),
               "the page shows the finished reply while the provider is still holding " <>
                 "the second half — so what it shows is not what was written so far"

        HeldProvider.release()
        await_quiet(context)
        {:ok, context}
      end
    end
  end
end
