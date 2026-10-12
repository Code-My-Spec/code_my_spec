defmodule CodeMySpec.Integrations.OAuthHandoffTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Integrations.OAuthHandoff

  setup do
    %{server: start_supervised!({OAuthHandoff, name: nil})}
  end

  defp flow(state), do: %{session_params: %{state: state}, provider: :google, flow: :integration}

  test "the browser's callback claims what the window parked, by its state", %{server: server} do
    :ok = OAuthHandoff.park(server, flow("s1"))

    assert {:ok, %{provider: :google, session_params: %{state: "s1"}}} =
             OAuthHandoff.claim(server, "s1")
  end

  test "a state is claimed once", %{server: server} do
    :ok = OAuthHandoff.park(server, flow("s1"))
    {:ok, _} = OAuthHandoff.claim(server, "s1")

    assert OAuthHandoff.claim(server, "s1") == :error
  end

  test "a state nobody parked, or none at all, claims nothing", %{server: server} do
    assert OAuthHandoff.claim(server, "never-parked") == :error
    assert OAuthHandoff.claim(server, nil) == :error
  end

  test "an abandoned flow expires", %{server: server} do
    :ok = OAuthHandoff.park(server, flow("s1"))
    send(server, {:expire, "s1"})

    assert OAuthHandoff.claim(server, "s1") == :error
  end
end
