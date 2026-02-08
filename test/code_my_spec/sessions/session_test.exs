defmodule CodeMySpec.Sessions.SessionTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.AgentTasks

  describe "changeset/2" do
    test "casts valid attributes into changeset" do
      attrs = %{
        id: Ecto.UUID.generate(),
        type: "ComponentSpec",
        priority: 10,
        status: "active",
        component_module_name: "MyApp.Users.User",
        external_conversation_id: "conv-123",
        state: %{"step" => "init"}
      }

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      assert get_change_or_data(changeset, :id) == attrs.id
      assert get_change_or_data(changeset, :type) == AgentTasks.ComponentSpec
      assert get_change_or_data(changeset, :priority) == 10
      assert get_change_or_data(changeset, :status) == :active
      assert get_change_or_data(changeset, :component_module_name) == attrs.component_module_name

      assert get_change_or_data(changeset, :external_conversation_id) ==
               attrs.external_conversation_id

      assert get_change_or_data(changeset, :state) == attrs.state
    end

    test "validates type is required" do
      attrs = %{
        status: "active",
        state: %{}
      }

      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "auto-generates id when not provided" do
      attrs = %{
        type: "ComponentSpec",
        status: "active"
      }

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      id = get_change_or_data(changeset, :id)
      assert id != nil
      assert is_binary(id)
      # Verify it's a valid UUID format
      assert {:ok, _} = Ecto.UUID.cast(id)
    end

    test "defaults status to active" do
      attrs = %{
        type: "ComponentSpec"
      }

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      assert get_change_or_data(changeset, :status) == :active
    end

    test "rejects unknown type values" do
      attrs = %{
        type: "UnknownTaskType",
        status: "active"
      }

      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
      assert %{type: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts all valid SessionType values" do
      valid_types = [
        "ComponentSpec",
        "ComponentCode",
        "ComponentTest",
        "ContextSpec",
        "ContextComponentSpecs",
        "ContextImplementation",
        "ContextDesignReview",
        "ArchitectureDesign",
        "ArchitectureReview",
        "ProjectSetup",
        "WriteBddSpecs"
      ]

      for type_string <- valid_types do
        attrs = %{type: type_string}
        changeset = Session.changeset(%Session{}, attrs)
        assert changeset.valid?, "Expected #{type_string} to be valid"
      end
    end

    test "accepts status as string and converts to atom" do
      for status <- ["active", "complete", "failed", "cancelled"] do
        attrs = %{type: "ComponentSpec", status: status}
        changeset = Session.changeset(%Session{}, attrs)
        assert changeset.valid?
        assert get_change_or_data(changeset, :status) == String.to_atom(status)
      end
    end

    test "validates priority is an integer when provided" do
      attrs = %{
        type: "ComponentSpec",
        priority: "not_a_number"
      }

      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
      assert %{priority: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "to_json/1" do
    test "produces a map that roundtrips through Jason.encode/decode" do
      session = %Session{
        id: Ecto.UUID.generate(),
        type: AgentTasks.ComponentSpec,
        priority: 10,
        status: :active,
        component_module_name: "MyApp.Users.User",
        external_conversation_id: "conv-123",
        state: %{"step" => "init"}
      }

      json_map = Session.to_json(session)

      # Should be encodable to JSON
      assert {:ok, json_string} = Jason.encode(json_map)

      # Should be decodable back
      assert {:ok, decoded} = Jason.decode(json_string)

      # Verify key fields are present
      assert decoded["id"] == session.id
      assert decoded["type"] == "ComponentSpec"
      assert decoded["priority"] == 10
      assert decoded["status"] == "active"
      assert decoded["component_module_name"] == "MyApp.Users.User"
      assert decoded["external_conversation_id"] == "conv-123"
      assert decoded["state"] == %{"step" => "init"}
    end

    test "converts atom fields to strings" do
      session = %Session{
        id: Ecto.UUID.generate(),
        type: AgentTasks.ComponentSpec,
        status: :active,
        state: %{}
      }

      json_map = Session.to_json(session)

      # Type should be converted from atom to string
      assert is_binary(json_map.type)
      assert json_map.type == "ComponentSpec"

      # Status should be converted from atom to string
      assert is_binary(json_map.status)
      assert json_map.status == "active"
    end

    test "handles nil optional fields" do
      session = %Session{
        id: Ecto.UUID.generate(),
        type: AgentTasks.ComponentSpec,
        status: :active,
        priority: nil,
        component_module_name: nil,
        external_conversation_id: nil,
        state: nil
      }

      json_map = Session.to_json(session)

      assert {:ok, _json_string} = Jason.encode(json_map)
      assert json_map.priority == nil
      assert json_map.component_module_name == nil
      assert json_map.external_conversation_id == nil
      assert json_map.state == nil
    end

    test "preserves complex state data structures" do
      session = %Session{
        id: Ecto.UUID.generate(),
        type: AgentTasks.ComponentSpec,
        status: :active,
        state: %{
          "nested" => %{
            "data" => [1, 2, 3],
            "flag" => true
          },
          "list" => ["a", "b", "c"]
        }
      }

      json_map = Session.to_json(session)

      assert {:ok, json_string} = Jason.encode(json_map)
      assert {:ok, decoded} = Jason.decode(json_string)

      assert decoded["state"]["nested"]["data"] == [1, 2, 3]
      assert decoded["state"]["nested"]["flag"] == true
      assert decoded["state"]["list"] == ["a", "b", "c"]
    end
  end

  describe "from_json/1" do
    test "reconstructs a Session struct from a JSON-decoded map" do
      json_map = %{
        "id" => Ecto.UUID.generate(),
        "type" => "ComponentSpec",
        "priority" => 10,
        "status" => "active",
        "component_module_name" => "MyApp.Users.User",
        "external_conversation_id" => "conv-123",
        "state" => %{"step" => "init"}
      }

      assert {:ok, %Session{} = session} = Session.from_json(json_map)

      assert session.id == json_map["id"]
      assert session.type == AgentTasks.ComponentSpec
      assert session.priority == 10
      assert session.status == :active
      assert session.component_module_name == "MyApp.Users.User"
      assert session.external_conversation_id == "conv-123"
      assert session.state == %{"step" => "init"}
    end

    test "returns error for invalid data" do
      invalid_map = %{
        "type" => "InvalidType",
        "status" => "active"
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Session.from_json(invalid_map)
      refute changeset.valid?
      assert %{type: ["is invalid"]} = errors_on(changeset)
    end

    test "returns error when required type field is missing" do
      invalid_map = %{
        "status" => "active",
        "state" => %{}
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Session.from_json(invalid_map)
      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "handles atom keys in addition to string keys" do
      json_map = %{
        id: Ecto.UUID.generate(),
        type: "ComponentSpec",
        status: "active",
        state: %{}
      }

      assert {:ok, %Session{} = session} = Session.from_json(json_map)
      assert session.type == AgentTasks.ComponentSpec
      assert session.status == :active
    end

    test "roundtrips through to_json and from_json" do
      original = %Session{
        id: Ecto.UUID.generate(),
        type: AgentTasks.ComponentSpec,
        priority: 10,
        status: :active,
        component_module_name: "MyApp.Users.User",
        external_conversation_id: "conv-123",
        state: %{"step" => "init", "data" => [1, 2, 3]}
      }

      json_map = Session.to_json(original)
      assert {:ok, reconstructed} = Session.from_json(json_map)

      assert reconstructed.id == original.id
      assert reconstructed.type == original.type
      assert reconstructed.priority == original.priority
      assert reconstructed.status == original.status
      assert reconstructed.component_module_name == original.component_module_name
      assert reconstructed.external_conversation_id == original.external_conversation_id
      assert reconstructed.state == original.state
    end

    test "auto-generates id if not present in JSON" do
      json_map = %{
        "type" => "ComponentSpec",
        "status" => "active"
      }

      assert {:ok, %Session{} = session} = Session.from_json(json_map)
      assert session.id != nil
      assert is_binary(session.id)
    end

    test "defaults status to active if not present" do
      json_map = %{
        "type" => "ComponentSpec"
      }

      assert {:ok, %Session{} = session} = Session.from_json(json_map)
      assert session.status == :active
    end
  end

  # Helper functions

  defp get_change_or_data(changeset, field) do
    case Ecto.Changeset.fetch_change(changeset, field) do
      {:ok, value} -> value
      :error -> Map.get(changeset.data, field)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
