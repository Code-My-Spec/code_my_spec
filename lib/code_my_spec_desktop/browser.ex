defmodule CodeMySpecDesktop.Browser do
  @moduledoc """
  Opens the user's default browser at the desktop app, once, as the last
  child of the tree (so the Endpoint is listening). `CMS_NO_BROWSER` skips it.
  Returns `:ignore`, so it occupies no process.
  """

  require Logger

  def child_spec(url),
    do: %{id: __MODULE__, start: {__MODULE__, :open, [url]}, restart: :temporary}

  def open(url) do
    if System.get_env("CMS_NO_BROWSER") in [nil, ""] do
      launch(url)
    else
      Logger.info("[Desktop] CMS_NO_BROWSER set, not opening #{url}")
    end

    :ignore
  end

  @doc "Open `url` in the default browser now, whatever CMS_NO_BROWSER says."
  @spec launch(String.t()) :: :ok
  def launch(url) do
    # `launch: false` in test: a test that runs a desktop flow opens no browser.
    if Application.get_env(:code_my_spec, __MODULE__, [])[:launch] != false do
      {cmd, args} = command(:os.type(), url)
      Task.start(fn -> System.cmd(cmd, args, stderr_to_stdout: true) end)
    end

    Logger.info("[Desktop] opening #{url}")
    :ok
  end

  def command({:unix, :darwin}, url), do: {"open", [url]}
  # `start`'s first quoted argument is a window title, hence the "".
  def command({:win32, _}, url), do: {"cmd", ["/c", "start", "", url]}
  def command({:unix, _}, url), do: {"xdg-open", [url]}
end
