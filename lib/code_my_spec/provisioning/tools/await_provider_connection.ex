defmodule CodeMySpec.Provisioning.Tools.AwaitProviderConnection do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.Tools.ConnectProvider

  # A tool called from `run_script` gets ~28s (its 30s wall clock less a margin);
  # a longer wait crashed `restart_app` the same way (issue 0b1ae6fc).
  @max_wait_seconds 25
  @default_wait_seconds 20
  @poll_ms 1_000

  @impl true
  def name, do: "await_provider_connection"

  @impl true
  def description do
    """
    Wait until a provider the person is approving (`connect_provider`) is
    connected, for up to `wait_seconds` (default #{@default_wait_seconds}, at most
    #{@max_wait_seconds}: a longer wait would outlive a script's clock). To keep
    waiting, call it again.

    Answers whether it is connected now, and never the credential itself. Not
    connected after the wait means the person has not approved yet: say so and
    call again, rather than minting a second link.
    """
  end

  @impl true
  def params do
    %{
      provider: {:required, {:meta, :string, [description: "The provider being connected."]}},
      wait_seconds:
        {:meta, :integer,
         [
           description:
             "How long to wait, in seconds. Default #{@default_wait_seconds}, at most #{@max_wait_seconds}; call again to keep waiting."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, provider} <- ConnectProvider.fetch_provider(params.provider) do
      wait = wait_seconds(params)

      if poll(scope, provider, System.monotonic_time(:millisecond) + wait * 1_000) do
        {:ok, "#{provider} is connected."}
      else
        {:ok,
         "#{provider} is not connected yet: the person has not approved it. " <>
           "Call await_provider_connection again to keep waiting."}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> CodeMySpec.Tools.error(reason)
    end
  end

  @doc false
  def wait_seconds(params),
    do:
      params |> Map.get(:wait_seconds, @default_wait_seconds) |> min(@max_wait_seconds) |> max(0)

  defp poll(scope, provider, deadline) do
    cond do
      ConnectProvider.connected?(scope, provider) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        poll(scope, provider, deadline)
    end
  end
end
