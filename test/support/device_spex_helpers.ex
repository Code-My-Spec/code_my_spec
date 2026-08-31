defmodule CodeMySpecSpex.DeviceHelpers do
  @moduledoc """
  The surfaces story 1020's criteria establish device state through.

  Twelve criteria need the same two things — a machine announcing itself, and a
  checkout saying which machine it is on — so they live here rather than being
  copied twelve times. A helper written twelve times is a parsing bug fixed
  eleven times and missed once.

  Neither of these reaches behind the app. A device exists because a harness
  announced it over the real route, and a working copy is on a device because a
  harness said so on the real channel. The same rule `WorkingCopyHelpers`
  follows.

  ## Why announcing is HTTP and not the channel

  A harness has no channel until it serves a project — `harness_project:<id>` is
  per project, and the light harness holds nothing else. But a machine is a
  machine before it has a checkout on it, which is the whole point of rule
  af7dcc7e. So the announce is a plain authenticated POST, the same shape
  `mix cms.harness.onboard` already uses to mint a working copy id, and it
  authenticates with either credential a machine can have: a laptop's OAuth
  token or a sprite's deploy key.
  """

  import Phoenix.ConnTest
  import ExUnit.Assertions

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  @doc """
  A machine announces itself, the way a harness does when it comes up.

  `device_id` is what the machine already holds — nil the first time, and the
  id it was issued on every start after. Returns the decoded body, which
  carries `device_id`.
  """
  @spec announce_device(map(), keyword()) :: map()
  def announce_device(context, opts \\ []) do
    context |> announce_response(opts) |> json_response(200)
  end

  @doc """
  The same announce, handed back unread.

  For the criteria about an announce being *refused*: asserting on the reply
  means the reply has to survive not being a 200.
  """
  @spec announce_response(map(), keyword()) :: Plug.Conn.t()
  def announce_response(context, opts \\ []) do
    body =
      %{
        "device_id" => Keyword.get(opts, :device_id),
        "hostname" => Keyword.get(opts, :hostname, "a-machine"),
        "kind" => Keyword.get(opts, :kind, "local")
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token(context, opts))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/devices", body)
  end

  @doc """
  Announce and hand back only the id, for the common case.
  """
  @spec device_id(map(), keyword()) :: String.t()
  def device_id(context, opts \\ []) do
    reply = announce_device(context, opts)

    assert is_binary(reply["device_id"]),
           "announcing did not return an identity: #{inspect(reply)}"

    reply["device_id"]
  end

  @doc """
  Announce as somebody else, so a criterion can present a device id that is
  genuinely another account's rather than one it invented.
  """
  @spec announce_as(map(), keyword()) :: map()
  def announce_as(other_context, opts), do: announce_device(other_context, opts)

  # The project's deploy key: a credential a *machine* holds, which is what is
  # announcing. A user's session is the wrong thing to authenticate this with —
  # a sprite has no signed-in user at all, and the route has to work for one.
  #
  # Set through the real changeset, because `put_deploy_key_hash/1` is what
  # makes the key findable: the API looks the project up by hash, so a key
  # written around the changeset authenticates nothing.
  defp token(context, _opts) do
    key = "dk_spex_device_#{:erlang.phash2(context.project.id)}"
    Fixtures.set_project_deploy_key(context.scope, context.project, key)
    key
  end
end
