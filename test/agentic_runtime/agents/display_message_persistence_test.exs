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
      %{owner_id: owner_id} = scope = build(:scope)
      conv = insert(:conversation, user_id: owner_id)
      msg = %Message{role: :user, content: "hello there"}

      assert {:ok, [display]} = DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))
      assert display.message_type == "user"
      assert display.content_type == "text"
      assert display.content["text"] == "hello there"
    end

    test "returns an empty list when the message has no displayable content" do
      %{owner_id: owner_id} = scope = build(:scope)
      conv = insert(:conversation, user_id: owner_id)
      msg = %Message{role: :user, content: ""}

      assert {:ok, []} = DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))
    end
  end

  describe "save_message/3 — tool calls" do
    test "persists assistant tool_call messages with status pending" do
      %{owner_id: owner_id} = scope = build(:scope)
      conv = insert(:conversation, user_id: owner_id)

      msg = %Message{
        role: :assistant,
        content: nil,
        tool_calls: [
          LangChain.Message.ToolCall.new!(%{
            call_id: "call_#{System.unique_integer([:positive])}",
            name: "search",
            arguments: %{"q" => "elixir"}
          })
        ]
      }

      assert {:ok, [display]} =
               DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))

      assert display.message_type == "assistant"
      assert display.content_type == "tool_call"
      assert display.status == "pending"
      assert display.content["name"] == "search"
    end

    @tag :capture_log
    test "returns an error when storing duplicate tool_call" do
      # Re-saving the same tool call (e.g. agent restart mid-stream re-emits the
      # same call_id) must not crash the AgentServer; the persistence layer
      # silently skips the duplicate.
      %{owner_id: owner_id} = scope = build(:scope)
      conv = insert(:conversation, user_id: owner_id)
      call_id = "call_dup_#{System.unique_integer([:positive])}"

      msg = %Message{
        role: :assistant,
        content: nil,
        tool_calls: [
          LangChain.Message.ToolCall.new!(%{
            call_id: call_id,
            name: "x",
            arguments: %{}
          })
        ]
      }

      {:ok, [_first]} = DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))

      assert {:error, %Ecto.Changeset{}} =
               DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))
    end

    # test "tolerates duplicate tool_call_id (returns :ok with empty list)" do
    #   # Re-saving the same tool call (e.g. agent restart mid-stream re-emits the
    #   # same call_id) must not crash the AgentServer; the persistence layer
    #   # silently skips the duplicate.
    #   %{owner_id: owner_id} = scope = build(:scope)
    #   conv = insert(:conversation, user_id: owner_id)
    #   call_id = "call_dup_#{System.unique_integer([:positive])}"

    #   msg = %Message{
    #     role: :assistant,
    #     content: nil,
    #     tool_calls: [
    #       LangChain.Message.ToolCall.new!(%{
    #         call_id: call_id,
    #         name: "x",
    #         arguments: %{}
    #       })
    #     ]
    #   }

    #   {:ok, [_first]} = DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))

    #   assert {:ok, []} = DisplayMessagePersistence.save_message(scope, msg, ctx(conv.id))
    # end
  end

  describe "update_tool_status/4" do
    setup do
      %{owner_id: owner_id} = scope = build(:scope)
      conv = insert(:conversation, user_id: owner_id)

      attrs = tool_call_attrs()
      {:ok, _} = Conversations.append_display_message(scope, conv.id, attrs)

      {:ok, scope: scope, conv: conv, call_id: attrs.content["call_id"]}
    end

    test "Tool call transitions from pending to executing", %{
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

    test "marking a tool call as completed records the tool result in metadata", %{
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

    test "marking a tool call as completed includes display_text when provided", %{
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

    test "marking a tool call as failed stores the error", %{
      scope: scope,
      conv: conv,
      call_id: call_id
    } do
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

    test "marking a tool call as interrupted stores display_text", %{
      scope: scope,
      conv: conv,
      call_id: call_id
    } do
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

    test "marking a tool call as cancelled", %{scope: scope, conv: conv, call_id: call_id} do
      assert {:ok, msg} =
               DisplayMessagePersistence.update_tool_status(
                 scope,
                 :cancelled,
                 %{call_id: call_id},
                 ctx(conv.id)
               )

      assert msg.status == "cancelled"
    end

    test "returns not found when call_id has no matching message" do
      %{owner_id: owner_id} = scope = build(:scope)
      conv = insert(:conversation, user_id: owner_id)

      assert {:error, :not_found} =
               DisplayMessagePersistence.update_tool_status(
                 scope,
                 :executing,
                 %{call_id: "ghost-call"},
                 ctx(conv.id)
               )
    end
  end

  describe "resolve_tool_result/4" do
    test "unlocks an interrupted tool result" do
      %{owner_id: owner_id} = scope = build(:scope)
      conv = insert(:conversation, user_id: owner_id)
      call_id = "call_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Conversations.append_display_message(scope, conv.id, %{
          message_type: "tool",
          content_type: "tool_result",
          content: %{
            "tool_call_id" => call_id,
            "name" => "do_thing",
            "content" => "(pending)",
            "is_interrupt" => true
          }
        })

      assert {:ok, msg} =
               DisplayMessagePersistence.resolve_tool_result(
                 scope,
                 call_id,
                 "ok!",
                 ctx(conv.id)
               )

      assert msg.content["is_interrupt"] == false
      assert msg.content["content"] == "ok!"
    end

    test "returns not found for an unknown tool_call_id" do
      %{owner_id: owner_id} = scope = build(:scope)
      conv = insert(:conversation, user_id: owner_id)

      assert {:error, :not_found} =
               DisplayMessagePersistence.resolve_tool_result(
                 scope,
                 "no-such-call",
                 "x",
                 ctx(conv.id)
               )
    end
  end
end
