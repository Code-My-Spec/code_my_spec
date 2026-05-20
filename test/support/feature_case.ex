defmodule CodeMySpecWeb.FeatureCase do
  @moduledoc """
  Case template for browser-driven end-to-end tests via Wallaby.

  Always tag the module with `@moduletag :e2e` so it's excluded by default.
  Opt in with `mix test --only e2e`.

  The Endpoint runs with `server: true` in test (see `config/test.exs`) and
  shares the SQL sandbox with Wallaby sessions via
  `Phoenix.Ecto.SQL.Sandbox` + Wallaby's built-in `feature/3` setup. Every
  test runs in its own transaction that rolls back at the end — no cross-
  test pollution, no manual cleanup, no production DB anywhere near it.

  The mailer is swapped to `TestMailbox` for the duration of each test so
  magic-link flows can capture URLs sent by the server process.

  Chrome capabilities are overridden from Wallaby's defaults: JS is
  enabled (LiveView needs it), and the user-agent is a real modern Chrome
  (the default fakes Chrome 41 which trips bot detectors and breaks
  LiveView's reconnect path).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      import Wallaby.Browser

      import Wallaby.Query,
        only: [
          css: 1,
          css: 2,
          link: 1,
          button: 1,
          text_field: 1,
          fillable_field: 1
        ]

      alias CodeMySpec.Support.TestMailbox

      # Override Wallaby's @sessions defaults: enable JS for LiveView and
      # ditch the fake Chrome 41 user-agent that bot detectors flag.
      @sessions [
        [
          capabilities:
            CodeMySpecWeb.FeatureCase.chrome_capabilities(
              headless: System.get_env("WALLABY_HEADLESS", "true") == "true"
            )
        ]
      ]
    end
  end

  setup _tags do
    original_mailer = Application.get_env(:code_my_spec, CodeMySpec.Mailer)
    Application.put_env(:code_my_spec, CodeMySpec.Mailer, adapter: CodeMySpec.Support.TestMailbox)
    CodeMySpec.Support.TestMailbox.clear()

    on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Mailer, original_mailer)
      CodeMySpec.Support.TestMailbox.clear()
    end)

    :ok
  end

  @doc """
  Build the Chrome capabilities map for Wallaby. Public so individual
  test modules can override (e.g. `WALLABY_HEADLESS=false mix test ...`
  doesn't recompile the case template).
  """
  def chrome_capabilities(opts) do
    headless = Keyword.get(opts, :headless, true)

    args =
      ["--no-sandbox", "window-size=1280,800", "--disable-gpu"] ++
        if(headless, do: ["--headless=new"], else: [])

    %{
      javascriptEnabled: true,
      loadImages: true,
      version: "",
      rotatable: false,
      takesScreenshot: true,
      cssSelectorsEnabled: true,
      nativeEvents: false,
      platform: "ANY",
      unhandledPromptBehavior: "accept",
      loggingPrefs: %{browser: "DEBUG"},
      chromeOptions: %{
        args: args,
        binary:
          System.get_env(
            "WALLABY_CHROME_BINARY",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
          )
      }
    }
  end
end
