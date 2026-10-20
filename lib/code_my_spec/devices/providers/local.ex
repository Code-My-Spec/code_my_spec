defmodule CodeMySpec.Devices.Providers.Local do
  @moduledoc "A dev box on Sam's own machine."
  @behaviour CodeMySpec.Devices.Provider

  @impl true
  def id, do: :local

  @impl true
  def label, do: "Local"

  @impl true
  def kind, do: :local

  @impl true
  def instructions(%{token: token, server_url: server_url}) do
    [
      %{
        key: "setup-local",
        copy: "copy-setup-local",
        title: "Start the harness on this machine",
        body: """
        Install cms, then start the harness with this box's token:

        brew install code-my-spec/tap/cms
        CMS_SERVER_URL=#{server_url} CMS_DEVICE_TOKEN=#{token} cms harness
        """
      }
    ]
  end
end
