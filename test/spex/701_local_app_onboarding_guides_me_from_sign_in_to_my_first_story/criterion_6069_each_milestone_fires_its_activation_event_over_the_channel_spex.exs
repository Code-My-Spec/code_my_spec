defmodule CodeMySpecSpex.Story701.Criterion6069Spex do
  @moduledoc """
  Story 701 — Local app onboarding guides me from sign-in to my first story.
  Criterion 6069 — Rule: The local app emits the five activation
  events to the dashboard server over the existing `cli:user:<id>`
  channel as each milestone lands.

  The five events: `:local_signed_in`, `:local_project_linked`,
  `:local_init_complete`, `:local_project_setup_complete`,
  `:first_local_story_created`.

  Each scenario covers exactly one milestone — the local app pushes
  one `activation_event` message and the analytics test subscriber
  receives the corresponding event. Splitting per-event keeps the
  contract for each milestone independently verifiable.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    :ok = Fixtures.attach_analytics_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_analytics_test_subscriber(self()) end)
    :ok
  end

  setup context do
    {:ok, _reply, channel_socket} =
      CodeMySpecWeb.UserSocket
      |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
      |> subscribe_and_join(
        CodeMySpecWeb.CliChannel,
        "cli:user:#{context.user.id}",
        %{}
      )

    wait_for_channel(channel_socket)
    {:ok, Map.put(context, :channel_socket, channel_socket)}
  end

  spex "Each onboarding milestone fires its activation event over the channel" do
    scenario "Sign-in milestone fires :local_signed_in" do
      when_ "the local app pushes a local_signed_in activation_event", context do
        Phoenix.ChannelTest.push(context.channel_socket, "activation_event", %{
          "name" => "local_signed_in",
          "payload" => %{"user_id" => context.user.id}
        })

        {:ok, context}
      end

      then_ "the analytics test subscriber receives :local_signed_in", context do
        user_id = context.user.id
        assert_receive {:analytics_event, :local_signed_in, %{user_id: ^user_id}}, 1_000
        {:ok, context}
      end
    end

    scenario "Project-linked milestone fires :local_project_linked" do
      when_ "the local app pushes a local_project_linked activation_event", context do
        Phoenix.ChannelTest.push(context.channel_socket, "activation_event", %{
          "name" => "local_project_linked",
          "payload" => %{"user_id" => context.user.id}
        })

        {:ok, context}
      end

      then_ "the analytics test subscriber receives :local_project_linked", context do
        user_id = context.user.id
        assert_receive {:analytics_event, :local_project_linked, %{user_id: ^user_id}}, 1_000
        {:ok, context}
      end
    end

    scenario "Init milestone fires :local_init_complete" do
      when_ "the local app pushes a local_init_complete activation_event", context do
        Phoenix.ChannelTest.push(context.channel_socket, "activation_event", %{
          "name" => "local_init_complete",
          "payload" => %{"user_id" => context.user.id}
        })

        {:ok, context}
      end

      then_ "the analytics test subscriber receives :local_init_complete", context do
        user_id = context.user.id
        assert_receive {:analytics_event, :local_init_complete, %{user_id: ^user_id}}, 1_000
        {:ok, context}
      end
    end

    scenario "Project-setup milestone fires :local_project_setup_complete" do
      when_ "the local app pushes a local_project_setup_complete activation_event", context do
        Phoenix.ChannelTest.push(context.channel_socket, "activation_event", %{
          "name" => "local_project_setup_complete",
          "payload" => %{"user_id" => context.user.id}
        })

        {:ok, context}
      end

      then_ "the analytics test subscriber receives :local_project_setup_complete",
            context do
        user_id = context.user.id

        assert_receive {:analytics_event, :local_project_setup_complete,
                        %{user_id: ^user_id}},
                       1_000

        {:ok, context}
      end
    end

    scenario "First-story milestone fires :first_local_story_created" do
      when_ "the local app pushes a first_local_story_created activation_event", context do
        Phoenix.ChannelTest.push(context.channel_socket, "activation_event", %{
          "name" => "first_local_story_created",
          "payload" => %{"user_id" => context.user.id}
        })

        {:ok, context}
      end

      then_ "the analytics test subscriber receives :first_local_story_created",
            context do
        user_id = context.user.id

        assert_receive {:analytics_event, :first_local_story_created, %{user_id: ^user_id}},
                       1_000

        {:ok, context}
      end
    end
  end
end
