defmodule CmsHarness.ChannelClientSocketOptionsTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Project.ChannelClient

  test "initial connections and retries retain the configured proxy and TLS options" do
    keys = [
      :harness_socket_options,
      :harness_deploy_key,
      :harness_server_url_override,
      CodeMySpec.Auth.HarnessOAuth
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:code_my_spec, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:code_my_spec, key, value)
          :error -> Application.delete_env(:code_my_spec, key)
        end
      end
    end)

    mint = [proxy: {:http, "proxy.example", 8080, []}, transport_opts: [verify: :verify_peer]]
    Application.put_env(:code_my_spec, :harness_socket_options, mint_opts: mint, test_mode?: true)
    Application.put_env(:code_my_spec, :harness_deploy_key, "test-token")

    Application.put_env(:code_my_spec, CodeMySpec.Auth.HarnessOAuth,
      state_dir:
        Path.join(System.tmp_dir!(), "cms-proxy-test-#{System.unique_integer([:positive])}")
    )

    Application.put_env(:code_my_spec, :harness_server_url_override, "https://server.example")

    {:ok, socket, _} = ChannelClient.init(%{id: "project", root: "/tmp/cms-proxy-test"})
    {:noreply, initial} = ChannelClient.handle_continue(:connect, socket)
    assert initial.channel_config.mint_opts == mint

    {:noreply, retry} = ChannelClient.handle_info(:reconnect, initial)
    assert retry.channel_config.mint_opts == mint
    assert retry.channel_config.uri.host == "server.example"
  end
end
