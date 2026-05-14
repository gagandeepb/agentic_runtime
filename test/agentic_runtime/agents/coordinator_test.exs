defmodule AgenticRuntime.Agents.CoordinatorTest do
  use AgenticRuntime.AgentCase, async: true

  alias AgenticRuntime.Agents.Coordinator
  alias AgenticRuntime.Conversations

  defp build_factory_opts do
    model = AgenticRuntime.build_anthropic_model_config("claude-opus-4-7", "k", [])

    [
      model_config: model,
      base_system_prompt: "Be helpful.",
      tools: []
    ]
  end

  describe "conversation_agent_id/1" do
    test "formats the agent id as conversation-<id>" do
      assert Coordinator.conversation_agent_id("abc-123") == "conversation-abc-123"
    end
  end

  describe "session_running?/1" do
    test "returns false when no agent is running" do
      conv_id = Ecto.UUID.generate()
      expected_id = "conversation-#{conv_id}"

      expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> nil end)

      refute Coordinator.session_running?(conv_id)
    end

    test "returns true when ServerAdapter reports a pid" do
      conv_id = Ecto.UUID.generate()
      expected_id = "conversation-#{conv_id}"

      expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> self() end)

      assert Coordinator.session_running?(conv_id)
    end
  end

  describe "stop_conversation_session/1" do
    test "no-ops when nothing is running" do
      conv_id = Ecto.UUID.generate()

      expect(ServerAdapter.Mock, :get_pid, fn _ -> nil end)

      assert {:ok, :not_running} = Coordinator.stop_conversation_session(conv_id)
    end

    test "calls stop on the adapter when running" do
      conv_id = Ecto.UUID.generate()
      expected_id = "conversation-#{conv_id}"

      expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> self() end)
      expect(ServerAdapter.Mock, :stop, fn ^expected_id -> :ok end)

      assert {:ok, :stopped} = Coordinator.stop_conversation_session(conv_id)
    end
  end

  describe "start_conversation_session/2" do
    # DISABLED (plan: valiant-twirling-crown): :filesystem_scope is now optional
    @tag :skip
    test "raises ArgumentError when :filesystem_scope is missing" do
      assert_raise ArgumentError, ~r/filesystem_scope/, fn ->
        Coordinator.start_conversation_session("conv-1", scope: build(:scope))
      end
    end

    test "returns the existing session when an agent is already running" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      expected_id = "conversation-#{conversation.id}"
      fake_pid = self()

      expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> fake_pid end)

      assert {:ok, session} =
               Coordinator.start_conversation_session(conversation.id,
                 scope: scope,
                 # DISABLED (plan: valiant-twirling-crown): filesystem_scope opt no longer needed
                 # filesystem_scope: {:user, scope.owner_id},
                 factory_opts: build_factory_opts()
               )

      assert session.agent_id == expected_id
      assert session.pid == fake_pid
    end

    test "starts a new session when none exists, using fresh state" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      expected_id = "conversation-#{conversation.id}"
      agent_pid = self()

      expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> nil end)

      expect(SupervisorAdapter.Mock, :start_agent_sync, fn opts ->
        assert opts[:agent_id] == expected_id
        assert %Sagents.Agent{} = opts[:agent]
        assert %Sagents.State{} = opts[:initial_state]
        assert opts[:initial_state].messages == []
        {:ok, self()}
      end)

      expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> agent_pid end)

      assert {:ok, session} =
               Coordinator.start_conversation_session(conversation.id,
                 scope: scope,
                 # DISABLED (plan: valiant-twirling-crown): filesystem_scope opt no longer needed
                 # filesystem_scope: {:user, scope.owner_id},
                 factory_opts: build_factory_opts()
               )

      assert session.agent_id == expected_id
      assert session.conversation_id == conversation.id
    end

    test "restores persisted state into the session when one exists" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      expected_id = "conversation-#{conversation.id}"

      saved_state = %{
        "version" => 1,
        "state" => %{
          "agent_id" => expected_id,
          "messages" => [
            %{
              "role" => "user",
              "content" => [%{"type" => "text", "content" => "remembered"}]
            }
          ],
          "version" => 1
        }
      }

      {:ok, _} = Conversations.save_agent_state(scope, conversation.id, saved_state)

      expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> nil end)

      expect(SupervisorAdapter.Mock, :start_agent_sync, fn opts ->
        state = opts[:initial_state]
        assert %Sagents.State{} = state
        assert length(state.messages) == 1
        {:ok, self()}
      end)

      expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> self() end)

      assert {:ok, _} =
               Coordinator.start_conversation_session(conversation.id,
                 scope: scope,
                 # DISABLED (plan: valiant-twirling-crown): filesystem_scope opt no longer needed
                 # filesystem_scope: {:user, scope.owner_id},
                 factory_opts: build_factory_opts()
               )
    end

    test "propagates supervisor errors as {:error, reason}" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)

      expect(ServerAdapter.Mock, :get_pid, fn _ -> nil end)
      expect(SupervisorAdapter.Mock, :start_agent_sync, fn _ -> {:error, :boom} end)

      assert {:error, :boom} =
               Coordinator.start_conversation_session(conversation.id,
                 scope: scope,
                 # DISABLED (plan: valiant-twirling-crown): filesystem_scope opt no longer needed
                 # filesystem_scope: {:user, scope.owner_id},
                 factory_opts: build_factory_opts()
               )
    end
  end

  describe "PubSub helpers" do
    test "ensure_subscribed_to_conversation receives broadcasts on the topic" do
      conv_id = Ecto.UUID.generate()
      :ok = Coordinator.ensure_subscribed_to_conversation(conv_id)

      topic = Coordinator.conversation_topic(conv_id)
      Phoenix.PubSub.broadcast(AgenticRuntime.TestPubSub, topic, {:test_event, "hello"})

      assert_receive {:test_event, "hello"}, 500
    end

    test "unsubscribe_from_conversation stops receiving broadcasts" do
      conv_id = Ecto.UUID.generate()
      :ok = Coordinator.ensure_subscribed_to_conversation(conv_id)
      :ok = Coordinator.unsubscribe_from_conversation(conv_id)

      topic = Coordinator.conversation_topic(conv_id)
      Phoenix.PubSub.broadcast(AgenticRuntime.TestPubSub, topic, {:should_not, "arrive"})

      refute_receive {:should_not, _}, 100
    end
  end

  describe "Presence helpers" do
    test "track_conversation_viewer + list_conversation_viewers" do
      conv_id = Ecto.UUID.generate()

      {:ok, _ref} = Coordinator.track_conversation_viewer(conv_id, "viewer-1", %{name: "Alice"})

      viewers = Coordinator.list_conversation_viewers(conv_id)
      assert Map.has_key?(viewers, "viewer-1")
    end

    test "untrack_conversation_viewer removes the viewer" do
      conv_id = Ecto.UUID.generate()

      {:ok, _ref} = Coordinator.track_conversation_viewer(conv_id, "viewer-2")
      :ok = Coordinator.untrack_conversation_viewer(conv_id, "viewer-2")

      refute Map.has_key?(Coordinator.list_conversation_viewers(conv_id), "viewer-2")
    end

    test "metadata stamped on the tracked entry includes joined_at and caller fields" do
      conv_id = Ecto.UUID.generate()

      {:ok, _ref} =
        Coordinator.track_conversation_viewer(conv_id, "viewer-meta", %{name: "Bob"})

      %{"viewer-meta" => %{metas: [meta | _]}} =
        Coordinator.list_conversation_viewers(conv_id)

      assert meta.name == "Bob"
      assert is_integer(meta.joined_at)
    end
  end

  describe "subscribe_to_conversation/1" do
    test "raw subscribe receives broadcasts on the agent topic" do
      conv_id = Ecto.UUID.generate()
      :ok = Coordinator.subscribe_to_conversation(conv_id)

      Phoenix.PubSub.broadcast(
        AgenticRuntime.TestPubSub,
        Coordinator.conversation_topic(conv_id),
        {:raw_event, "ping"}
      )

      assert_receive {:raw_event, "ping"}, 500
    end
  end

  describe "config getters" do
    test "conversation_topic/1 returns the agent_server:<agent_id> topic" do
      conv_id = "fixed-id"
      assert Coordinator.conversation_topic(conv_id) == "agent_server:conversation-fixed-id"
    end

    test "pubsub_name/0 returns the value configured under :agentic_runtime" do
      assert Coordinator.pubsub_name() == AgenticRuntime.TestPubSub
    end

    test "presence_module/0 returns the value configured under :agentic_runtime" do
      assert Coordinator.presence_module() == AgenticRuntime.TestPresence
    end
  end
end
