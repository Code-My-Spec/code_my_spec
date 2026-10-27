defmodule CodeMySpecSpex.Story1149.Criterion2410Spex do
  @moduledoc "Main discovers copies on two devices and names either by ID."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.AttachmentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's Main lists copies on two devices", criterion: 2410 do
    scenario "both copies have IDs and devices and can be named without a path" do
      given_ "Sam has laptop and remote working copies", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main lists the project's working copies", context do
        copies = AttachmentHelpers.data(context, "list_working_copies")
        {:ok, Map.put(context, :listed_copies, copies)}
      end

      then_ "each copy is shown with its ID and device", context do
        one_id = context.one.id
        two_id = context.two.id
        assert %{"id" => ^one_id, "device_name" => "laptop"} =
                 Enum.find(context.listed_copies, &(&1["id"] == one_id))
        assert %{"id" => ^two_id, "device_name" => "remote"} =
                 Enum.find(context.listed_copies, &(&1["id"] == two_id))
        {:ok, context}
      end

      then_ "Main can name either copy without a filesystem path", context do
        assert AttachmentHelpers.read(context, context.one, "identity.txt") =~ "laptop"
        assert AttachmentHelpers.read(context, context.two, "identity.txt") =~ "remote"
        {:ok, context}
      end
    end
  end
end
