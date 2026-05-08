defmodule AgenticRuntime.Agents.DisplayMessagePersistenceTest do
  use AgenticRuntime.DataCase, async: true

  alias AgenticRuntime.Agents.DisplayMessagePersistence
  alias AgenticRuntime.Conversations
  alias LangChain.Message

  defp ctx(conversation_id, agent_id \\ nil) do
    %{
      agent_id: agent_id || "conversation-#{conversation_id}",
      conversation_id: conversation_id,
      lifecycle: :on_message
    }
  end

  describe "save_message/3" do
    test "persists a user text message as a DisplayMessage row" do
      scope = build_scope()
      conv = insert_conversation!(scope)
      msg = %Message{role: :user, content: "hello there"}

      assert {:ok, [display]} = DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))
      assert display.message_type == "user"
      assert display.content_type == "text"
      assert display.content["text"] == "hello there"
    end

    test "returns {:ok, []} when the message has no displayable content" do
      scope = build_scope()
      conv = insert_conversation!(scope)
      msg = %Message{role: :user, content: ""}

      assert {:ok, []} = DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))
    end
  end

  describe "update_tool_status/4" do
    setup do
      scope = build_scope()
      conv = insert_conversation!(scope)

      attrs = tool_call_attrs()
      {:ok, _} = Conversations.append_display_message(scope, conv.id, attrs)

      {:ok, scope: scope, conv: conv, call_id: attrs.content["call_id"]}
    end

    test ":executing transitions pending -> executing", %{
      scope: scope,
      conv: conv,
      call_id: call_id
    } do
      assert {:ok, %{status: "executing"}} =
               DisplayMessagePersistence.update_tool_status(
                 scope,
                 :executing,
                 %{call_id: call_id},
                 ctx(conv.id)
               )
    end

    test ":completed records the tool result in metadata", %{
      scope: scope,
      conv: conv,
      call_id: call_id
    } do
      assert {:ok, msg} =
               DisplayMessagePersistence.update_tool_status(
                 scope,
                 :completed,
                 %{call_id: call_id, result: "{\"answer\": 42}"},
                 ctx(conv.id)
               )

      assert msg.status == "completed"
      assert msg.metadata["result"] == "{\"answer\": 42}"
    end

    test ":completed includes display_text when provided", %{
      scope: scope,
      conv: conv,
      call_id: call_id
    } do
      assert {:ok, msg} =
               DisplayMessagePersistence.update_tool_status(
                 scope,
                 :completed,
                 %{call_id: call_id, result: "ok", display_text: "fetched 5 rows"},
                 ctx(conv.id)
               )

      assert msg.metadata["display_text"] == "fetched 5 rows"
    end

    test ":failed stores the error", %{scope: scope, conv: conv, call_id: call_id} do
      assert {:ok, msg} =
               DisplayMessagePersistence.update_tool_status(
                 scope,
                 :failed,
                 %{call_id: call_id, error: "boom"},
                 ctx(conv.id)
               )

      assert msg.status == "failed"
      assert msg.metadata["error"] == "boom"
    end

    test ":interrupted stores display_text", %{scope: scope, conv: conv, call_id: call_id} do
      assert {:ok, msg} =
               DisplayMessagePersistence.update_tool_status(
                 scope,
                 :interrupted,
                 %{call_id: call_id, display_text: "needs approval"},
                 ctx(conv.id)
               )

      assert msg.status == "interrupted"
      assert msg.metadata["display_text"] == "needs approval"
    end

    test ":cancelled transitions to cancelled", %{scope: scope, conv: conv, call_id: call_id} do
      assert {:ok, msg} =
               DisplayMessagePersistence.update_tool_status(
                 scope,
                 :cancelled,
                 %{call_id: call_id},
                 ctx(conv.id)
               )

      assert msg.status == "cancelled"
    end
  end
end
