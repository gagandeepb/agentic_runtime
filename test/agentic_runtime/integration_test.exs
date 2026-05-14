defmodule AgenticRuntime.IntegrationTest do
  @moduledoc """
  End-to-end persistence wiring tests.

  These tests exercise the full slice from `Coordinator.start_conversation_session/2`
  down through the supervisor wire-up into the real `AgentPersistence` and
  `DisplayMessagePersistence` callbacks against the test repo. The
  `SupervisorAdapter`/`ServerAdapter` boundaries are mocked so no real
  `Sagents.AgentServer` is started — instead the test inspects the
  `supervisor_config` the coordinator hands to the supervisor and then drives
  the persistence callbacks directly to simulate what an AgentServer would do
  during a streaming run.

  Tagged `:integration` so they can be excluded from the fast unit run via
  `mix test --exclude integration` (the test_helper excludes them by default).
  """

  use AgenticRuntime.AgentCase, async: true

  @moduletag :integration

  alias AgenticRuntime.Agents.AgentPersistence
  alias AgenticRuntime.Agents.Coordinator
  alias AgenticRuntime.Agents.DisplayMessagePersistence
  alias AgenticRuntime.Conversations
  alias AgenticRuntime.Conversations.AgentState
  alias AgenticRuntime.Conversations.DisplayMessage
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  defp build_factory_opts do
    model = AgenticRuntime.build_anthropic_model_config("claude-opus-4-7", "k", [])

    [
      model_config: model,
      base_system_prompt: "Be helpful.",
      tools: []
    ]
  end

  # Capture the supervisor_config the coordinator sends to start_agent_sync,
  # so we can verify wire-up *and* drive the persistence callbacks ourselves.
  defp capture_supervisor_config_into(test_pid, expected_id) do
    expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> nil end)

    expect(SupervisorAdapter.Mock, :start_agent_sync, fn config ->
      send(test_pid, {:supervisor_config, config})
      {:ok, self()}
    end)

    expect(ServerAdapter.Mock, :get_pid, fn ^expected_id -> self() end)
  end

  describe "text-only flow" do
    test "session start wires up persistence; appended messages land in the DB" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      expected_id = "conversation-#{conversation.id}"

      capture_supervisor_config_into(self(), expected_id)

      assert {:ok, %{agent_id: ^expected_id}} =
               Coordinator.start_conversation_session(conversation.id,
                 scope: scope,
                 factory_opts: build_factory_opts()
               )

      assert_received {:supervisor_config, config}
      assert config[:agent_persistence] == AgentPersistence
      assert config[:display_message_persistence] == DisplayMessagePersistence
      assert config[:conversation_id] == conversation.id
      assert %Sagents.State{messages: []} = config[:initial_state]

      ctx = %{
        agent_id: expected_id,
        conversation_id: conversation.id,
        lifecycle: :on_message
      }

      {:ok, [_user]} =
        DisplayMessagePersistence.save_message(
          scope,
          %Message{role: :user, content: "what's the weather?"},
          ctx
        )

      {:ok, [_assistant]} =
        DisplayMessagePersistence.save_message(
          scope,
          %Message{role: :assistant, content: "rainy"},
          ctx
        )

      :ok =
        AgentPersistence.persist_state(
          scope,
          %{"version" => 2, "state" => %{"messages" => ["m1", "m2"]}},
          ctx
        )

      messages = Conversations.load_display_messages(scope, conversation.id)
      assert Enum.map(messages, & &1.content["text"]) == ["what's the weather?", "rainy"]
      assert Enum.map(messages, & &1.message_type) == ["user", "assistant"]

      [%AgentState{} = persisted] =
        TestRepo.all(from(s in AgentState, where: s.conversation_id == ^conversation.id))

      assert persisted.version == 2
      assert persisted.state_data["state"]["messages"] == ["m1", "m2"]
    end

    test "second start_session loads the persisted state into initial_state" do
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

      capture_supervisor_config_into(self(), expected_id)

      assert {:ok, _} =
               Coordinator.start_conversation_session(conversation.id,
                 scope: scope,
                 factory_opts: build_factory_opts()
               )

      assert_received {:supervisor_config, config}
      assert %Sagents.State{messages: [_one]} = config[:initial_state]
    end
  end

  describe "tool-call lifecycle" do
    test "save_message → mark_executing → complete persists each transition" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)

      ctx = %{
        agent_id: "conversation-#{conversation.id}",
        conversation_id: conversation.id,
        lifecycle: :on_message
      }

      call_id = "call_#{System.unique_integer([:positive])}"

      tool_call_message = %Message{
        role: :assistant,
        content: nil,
        tool_calls: [
          ToolCall.new!(%{call_id: call_id, name: "search", arguments: %{"q" => "x"}})
        ]
      }

      {:ok, [%DisplayMessage{} = pending]} =
        DisplayMessagePersistence.save_message(scope, tool_call_message, ctx)

      assert pending.status == "pending"
      assert pending.content_type == "tool_call"

      {:ok, %DisplayMessage{status: "executing"}} =
        DisplayMessagePersistence.update_tool_status(scope, :executing, %{call_id: call_id}, ctx)

      {:ok, %DisplayMessage{status: "completed"} = done} =
        DisplayMessagePersistence.update_tool_status(
          scope,
          :completed,
          %{call_id: call_id, result: "ok"},
          ctx
        )

      assert done.metadata["result"] == "ok"

      [%DisplayMessage{} = reloaded] = Conversations.load_display_messages(scope, conversation.id)
      assert reloaded.status == "completed"
      assert reloaded.content["call_id"] == call_id
    end
  end

  describe "HITL interrupt + resume" do
    test "interrupt → hitl decision → resolve flips is_interrupt and stamps decision" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)

      ctx = %{
        agent_id: "conversation-#{conversation.id}",
        conversation_id: conversation.id,
        lifecycle: :on_message
      }

      call_id = "call_hitl_#{System.unique_integer([:positive])}"

      {:ok, [_]} =
        DisplayMessagePersistence.save_message(
          scope,
          %Message{
            role: :assistant,
            content: nil,
            tool_calls: [
              ToolCall.new!(%{call_id: call_id, name: "delete_all", arguments: %{}})
            ]
          },
          ctx
        )

      {:ok, _} =
        DisplayMessagePersistence.update_tool_status(
          scope,
          :interrupted,
          %{call_id: call_id, display_text: "needs approval"},
          ctx
        )

      {:ok, _} =
        Conversations.append_display_message(scope, conversation.id, %{
          message_type: "tool",
          content_type: "tool_result",
          content: %{
            "tool_call_id" => call_id,
            "name" => "delete_all",
            "content" => "(pending)",
            "is_interrupt" => true
          }
        })

      {:ok, tool_call_msg} = Conversations.record_hitl_decision(scope, call_id, "approved")
      assert tool_call_msg.metadata["hitl_decision"] == "approved"

      {:ok, resolved_result} =
        DisplayMessagePersistence.resolve_tool_result(scope, call_id, "deleted: 4 rows", ctx)

      assert resolved_result.content["is_interrupt"] == false
      assert resolved_result.content["content"] == "deleted: 4 rows"
      assert resolved_result.content["hitl_decision"] == "approved"
    end
  end
end
