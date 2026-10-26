defmodule CodeMySpecSpex.Story1135.Criterion2326Spex do
  @moduledoc """
  Story 1135 — I connect a Claude Code cloud environment.
  Criterion 2326 — Sam copies the environment setup.

  The three things Sam pastes into the environment. The network secret's *value*
  is the bare token: Anthropic's proxy adds `Bearer ` itself, so the copy button
  holds the token and nothing else. The script needs no deploy key (the box
  onboards from its token, issue 2dae034c) and the allowlist carries no probe
  hosts.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "DevOps gives the script, the hosts and the secret, each copyable", criterion: 2326 do
    scenario "Sam added a Claude Code cloud box" do
      given_ "Sam added a Claude Code cloud box", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        {:ok, Map.merge(context, %{live: live, box: box})}
      end

      then_ "DevOps shows the setup script, the hosts to allow and the network secret", context do
        for key <- ~w(setup-script setup-hosts setup-network-secret) do
          assert has_element?(context.live, "[data-test='#{key}']"),
                 "the page shows no #{key}"
        end

        {:ok, context}
      end

      then_ "the network secret's value is the bare token", context do
        assert copy_value(context.live, "copy-network-secret") == context.box.token,
               "the secret's copy button holds more (or less) than the bare token"

        {:ok, context}
      end

      then_ "each has a copy button", context do
        for key <- ~w(copy-setup-script copy-setup-hosts copy-network-secret) do
          assert has_element?(context.live, "[data-test='#{key}'][data-copy]"),
                 "no copy button #{key}"
        end

        {:ok, context}
      end

      then_ "the script installs browser tooling before QA and allows its download hosts",
            context do
        script = shown_setup_script(context.live)
        refute script =~ "CMS_DEPLOY_KEY", "the script still reads a deploy key"
        assert script =~ "npm install -g vibium"
        assert script =~ "vibium install"
        assert script =~ "vibium ready browser chrome"
        assert script =~ "VIBIUM_CACHE_DIR=/opt/vibium-cache"
        assert script =~ "VIBIUM_CACHE_DIR: \"/opt/vibium-cache\""
        assert script =~ "NO_PROXY=\"$vibium_no_proxy\""

        hosts = copy_value(context.live, "copy-setup-hosts")

        for host <- ~w(registry.npmjs.org googlechromelabs.github.io storage.googleapis.com) do
          assert hosts =~ host, "the copied allowlist omits #{host}"
        end

        refute hosts =~ "echo.websocket.org"
        refute hosts =~ "httpbin.org"
        {:ok, context}
      end
    end
  end

  defp copy_value(live, copy_key) do
    live
    |> element("[data-test='#{copy_key}']")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("data-copy")
    |> List.first()
  end
end
