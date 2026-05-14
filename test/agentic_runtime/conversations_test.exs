defmodule AgenticRuntime.ConversationsTest do
  use AgenticRuntime.DataCase, async: true

  alias AgenticRuntime.Conversations
  alias AgenticRuntime.Conversations.Conversation
  alias AgenticRuntime.Conversations.DisplayMessage

  describe "create_conversation/2" do
    test "associates the conversation with the scope's owner" do
      scope = build(:scope)
      attrs = conversation_attrs(%{title: "Hello"})

      assert {:ok, %Conversation{} = conversation} =
               Conversations.create_conversation(scope, attrs)

      assert conversation.title == "Hello"
      assert conversation.user_id == scope.owner_id
    end

    test "raises Protocol.UndefinedError when scope is nil" do
      assert_raise Protocol.UndefinedError, fn ->
        Conversations.create_conversation(nil, conversation_attrs())
      end
    end
  end

  describe "get_conversation/2 + get_conversation!/2" do
    setup do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      {:ok, scope: scope, conversation: conversation}
    end

    test "returns {:ok, conversation} when scope owns it", %{scope: scope, conversation: c} do
      assert {:ok, found} = Conversations.get_conversation(scope, c.id)
      assert found.id == c.id
    end

    test "returns {:error, :not_found} when a different scope tries to read it", %{
      conversation: c
    } do
      other_scope = build(:scope)
      assert {:error, :not_found} = Conversations.get_conversation(other_scope, c.id)
    end

    test "bang variant raises Ecto.NoResultsError when scope mismatch", %{conversation: c} do
      other_scope = build(:scope)

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(other_scope, c.id)
      end
    end
  end

  describe "list_conversations/2" do
    test "only returns conversations owned by the scope" do
      %{owner_id: owner_a} = scope_a = build(:scope)
      %{owner_id: owner_b} = scope_b = build(:scope)

      _ = insert(:conversation, user_id: owner_a, title: "A1")
      _ = insert(:conversation, user_id: owner_a, title: "A2")
      _ = insert(:conversation, user_id: owner_b, title: "B1")

      titles_a = scope_a |> Conversations.list_conversations() |> Enum.map(& &1.title)
      titles_b = scope_b |> Conversations.list_conversations() |> Enum.map(& &1.title)

      assert Enum.sort(titles_a) == ["A1", "A2"]
      assert titles_b == ["B1"]
    end

    test "honours :limit and :offset" do
      %{owner_id: owner_id} = scope = build(:scope)
      for i <- 1..5, do: insert(:conversation, user_id: owner_id, title: "C#{i}")

      assert length(Conversations.list_conversations(scope, limit: 2)) == 2
      assert length(Conversations.list_conversations(scope, limit: 2, offset: 4)) == 1
    end
  end

  describe "update_conversation/2 + delete_conversation/{1,2}" do
    setup do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id, title: "Original")
      {:ok, scope: scope, conversation: conversation}
    end

    test "updates fields on a conversation struct", %{conversation: c} do
      assert {:ok, updated} = Conversations.update_conversation(c, %{title: "Renamed"})
      assert updated.title == "Renamed"
    end

    test "delete_conversation/1 removes the row", %{conversation: c} do
      assert {:ok, _} = Conversations.delete_conversation(c)
      assert TestRepo.get(Conversation, c.id) == nil
    end

    test "delete_conversation/2 enforces scope", %{conversation: c} do
      other_scope = build(:scope)

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.delete_conversation(other_scope, c.id)
      end

      refute is_nil(TestRepo.get(Conversation, c.id))
    end
  end

  describe "save_agent_state/3 + load_agent_state/2" do
    setup do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      {:ok, scope: scope, conversation: conversation}
    end

    test "round-trips arbitrary state data", %{scope: scope, conversation: c} do
      state = %{"version" => 2, "state" => %{"messages" => [%{"role" => "user"}]}}

      assert {:ok, _} = Conversations.save_agent_state(scope, c.id, state)
      assert {:ok, loaded} = Conversations.load_agent_state(scope, c.id)
      assert loaded == state
    end

    test "upserts on second call (single agent_state per conversation)", %{
      scope: scope,
      conversation: c
    } do
      assert {:ok, _} =
               Conversations.save_agent_state(scope, c.id, %{"version" => 1, "state" => %{}})

      assert {:ok, _} =
               Conversations.save_agent_state(scope, c.id, %{
                 "version" => 2,
                 "state" => %{"updated" => true}
               })

      assert {:ok, loaded} = Conversations.load_agent_state(scope, c.id)
      assert loaded["state"]["updated"] == true
      assert loaded["version"] == 2
    end

    test "rejects writes from a different scope", %{conversation: c} do
      other_scope = build(:scope)

      assert {:error, :not_found} =
               Conversations.save_agent_state(other_scope, c.id, %{"version" => 1, "state" => %{}})
    end

    test "rejects reads from a different scope", %{scope: scope, conversation: c} do
      :ok =
        elem(Conversations.save_agent_state(scope, c.id, %{"version" => 1, "state" => %{}}), 0)

      other_scope = build(:scope)
      assert {:error, :not_found} = Conversations.load_agent_state(other_scope, c.id)
    end

    test "load_agent_state returns :not_found when nothing has been persisted", %{
      scope: scope,
      conversation: c
    } do
      assert {:error, :not_found} = Conversations.load_agent_state(scope, c.id)
    end
  end

  describe "display messages — append_display_message/3 and load_display_messages/3" do
    setup do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      {:ok, scope: scope, conversation: conversation}
    end

    test "preserves chronological + sequence ordering", %{scope: scope, conversation: c} do
      {:ok, _} =
        Conversations.append_display_message(
          scope,
          c.id,
          text_message_attrs(%{message_type: "user", content: %{"text" => "first"}})
        )

      {:ok, _} =
        Conversations.append_display_message(
          scope,
          c.id,
          text_message_attrs(%{
            message_type: "assistant",
            content_type: "thinking",
            sequence: 0,
            content: %{"text" => "...thinking..."}
          })
        )

      {:ok, _} =
        Conversations.append_display_message(
          scope,
          c.id,
          text_message_attrs(%{
            message_type: "assistant",
            sequence: 1,
            content: %{"text" => "answer"}
          })
        )

      messages = Conversations.load_display_messages(scope, c.id)
      texts = Enum.map(messages, & &1.content["text"])
      assert texts == ["first", "...thinking...", "answer"]
    end

    test "respects :limit and :offset", %{scope: scope, conversation: c} do
      for i <- 1..4 do
        {:ok, _} =
          Conversations.append_display_message(
            scope,
            c.id,
            text_message_attrs(%{content: %{"text" => "msg#{i}"}})
          )
      end

      assert length(Conversations.load_display_messages(scope, c.id, limit: 2)) == 2

      assert length(Conversations.load_display_messages(scope, c.id, limit: 10, offset: 3)) ==
               1
    end

    test "load returns [] for a different scope", %{scope: scope, conversation: c} do
      {:ok, _} =
        Conversations.append_display_message(scope, c.id, text_message_attrs())

      assert Conversations.load_display_messages(build(:scope), c.id) == []
    end

    test "append rejects writes from a different scope", %{conversation: c} do
      assert {:error, :not_found} =
               Conversations.append_display_message(build(:scope), c.id, text_message_attrs())
    end
  end

  describe "tool call lifecycle" do
    setup do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      attrs = tool_call_attrs()

      {:ok, %DisplayMessage{} = tool_call} =
        Conversations.append_display_message(scope, conversation.id, attrs)

      {:ok,
       scope: scope,
       conversation: conversation,
       call_id: attrs.content["call_id"],
       tool_call: tool_call}
    end

    test "mark_tool_executing transitions pending -> executing", %{scope: scope, call_id: call_id} do
      assert {:ok, %DisplayMessage{status: "executing"}} =
               Conversations.mark_tool_executing(scope, call_id)
    end

    test "mark_tool_executing is idempotent — second call returns :not_found", %{
      scope: scope,
      call_id: call_id
    } do
      {:ok, _} = Conversations.mark_tool_executing(scope, call_id)
      assert {:error, :not_found} = Conversations.mark_tool_executing(scope, call_id)
    end

    test "complete_tool_call merges metadata and sets status", %{scope: scope, call_id: call_id} do
      assert {:ok, %DisplayMessage{} = msg} =
               Conversations.complete_tool_call(scope, call_id, %{"result" => "ok"})

      assert msg.status == "completed"
      assert msg.metadata["result"] == "ok"
    end

    test "fail_tool_call records the error info", %{scope: scope, call_id: call_id} do
      assert {:ok, %DisplayMessage{status: "failed", metadata: %{"reason" => "boom"}}} =
               Conversations.fail_tool_call(scope, call_id, %{"reason" => "boom"})
    end

    test "interrupt_tool_call only matches pending or executing", %{
      scope: scope,
      call_id: call_id
    } do
      assert {:ok, %DisplayMessage{status: "interrupted"}} =
               Conversations.interrupt_tool_call(scope, call_id)

      assert {:error, :not_found} = Conversations.interrupt_tool_call(scope, call_id)
    end

    test "cancel_tool_call accepts pending/executing/interrupted", %{
      scope: scope,
      call_id: call_id
    } do
      assert {:ok, %DisplayMessage{status: "cancelled"}} =
               Conversations.cancel_tool_call(scope, call_id)
    end

    test "wrong-scope callers cannot mutate tool calls", %{call_id: call_id} do
      other = build(:scope)
      assert {:error, :not_found} = Conversations.mark_tool_executing(other, call_id)
      assert {:error, :not_found} = Conversations.complete_tool_call(other, call_id, %{})
      assert {:error, :not_found} = Conversations.fail_tool_call(other, call_id, %{})
      assert {:error, :not_found} = Conversations.cancel_tool_call(other, call_id)
    end
  end

  describe "record_hitl_decision/3" do
    setup do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      attrs = tool_call_attrs()

      {:ok, _} =
        Conversations.append_display_message(scope, conversation.id, attrs)

      {:ok, scope: scope, conversation: conversation, call_id: attrs.content["call_id"]}
    end

    test "writes the decision into the tool_call metadata", %{scope: scope, call_id: call_id} do
      assert {:ok, msg} = Conversations.record_hitl_decision(scope, call_id, "approved")
      assert msg.metadata["hitl_decision"] == "approved"
    end

    test "rejects scope mismatch", %{call_id: call_id} do
      assert {:error, :not_found} =
               Conversations.record_hitl_decision(build(:scope), call_id, "rejected")
    end
  end

  describe "search_messages/2" do
    test "finds messages by content substring within scope" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)

      {:ok, _} =
        Conversations.append_display_message(
          scope,
          conversation.id,
          text_message_attrs(%{content: %{"text" => "the quick brown fox"}})
        )

      {:ok, _} =
        Conversations.append_display_message(
          scope,
          conversation.id,
          text_message_attrs(%{content: %{"text" => "an entirely different message"}})
        )

      results = Conversations.search_messages(scope, "brown")
      assert length(results) == 1
      assert hd(results).content["text"] =~ "brown"
    end

    test "does not return messages from another scope" do
      %{owner_id: owner_a} = scope_a = build(:scope)
      scope_b = build(:scope)

      conversation_a = insert(:conversation, user_id: owner_a)

      {:ok, _} =
        Conversations.append_display_message(
          scope_a,
          conversation_a.id,
          text_message_attrs(%{content: %{"text" => "secret data"}})
        )

      assert Conversations.search_messages(scope_b, "secret") == []
    end

    test "returns [] when no message matches" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)

      {:ok, _} =
        Conversations.append_display_message(
          scope,
          conversation.id,
          text_message_attrs(%{content: %{"text" => "lorem ipsum"}})
        )

      assert Conversations.search_messages(scope, "nothing-here") == []
    end

    test "is case-insensitive (ILIKE)" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)

      {:ok, _} =
        Conversations.append_display_message(
          scope,
          conversation.id,
          text_message_attrs(%{content: %{"text" => "Ferrari"}})
        )

      assert [_] = Conversations.search_messages(scope, "ferrari")
    end

    test "matches across content_types because the JSONB blob is stringified" do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)

      {:ok, _} =
        Conversations.append_display_message(
          scope,
          conversation.id,
          tool_call_attrs(%{
            content: %{
              "call_id" => "call_search_1",
              "name" => "lookup_unicorn",
              "arguments" => %{"q" => "x"}
            }
          })
        )

      assert [_] = Conversations.search_messages(scope, "lookup_unicorn")
    end
  end

  describe "append_text_message/4" do
    test "creates a text-content display message in the given role" do
      %{owner_id: owner_id} = scope = build(:scope)
      c = insert(:conversation, user_id: owner_id)

      assert {:ok, %DisplayMessage{} = msg} =
               Conversations.append_text_message(scope, c.id, "assistant", "hi there")

      assert msg.message_type == "assistant"
      assert msg.content_type == "text"
      assert msg.content == %{"text" => "hi there"}
    end

    test "rejects scope mismatch" do
      %{owner_id: owner_id} = build(:scope)
      c = insert(:conversation, user_id: owner_id)

      assert {:error, :not_found} =
               Conversations.append_text_message(build(:scope), c.id, "user", "x")
    end
  end

  describe "load_todos/2" do
    test "returns [] when no agent state has been persisted" do
      %{owner_id: owner_id} = scope = build(:scope)
      c = insert(:conversation, user_id: owner_id)

      assert Conversations.load_todos(scope, c.id) == []
    end

    test "returns [] when state has no todos field" do
      %{owner_id: owner_id} = scope = build(:scope)
      c = insert(:conversation, user_id: owner_id)

      {:ok, _} =
        Conversations.save_agent_state(scope, c.id, %{
          "version" => 1,
          "state" => %{"messages" => []}
        })

      assert Conversations.load_todos(scope, c.id) == []
    end

    test "decodes valid todo maps via Sagents.Todo.from_map/1" do
      %{owner_id: owner_id} = scope = build(:scope)
      c = insert(:conversation, user_id: owner_id)

      todo = %{
        "id" => "todo-1",
        "content" => "write tests",
        "status" => "pending",
        "active_form" => "writing tests"
      }

      {:ok, _} =
        Conversations.save_agent_state(scope, c.id, %{
          "version" => 1,
          "state" => %{"todos" => [todo]}
        })

      assert [%Sagents.Todo{content: "write tests"}] = Conversations.load_todos(scope, c.id)
    end

    test "returns [] when scope cannot read the conversation" do
      %{owner_id: owner_id} = scope = build(:scope)
      c = insert(:conversation, user_id: owner_id)

      {:ok, _} =
        Conversations.save_agent_state(scope, c.id, %{
          "version" => 1,
          "state" => %{"todos" => []}
        })

      assert Conversations.load_todos(build(:scope), c.id) == []
    end
  end

  describe "resolve_interrupted_tool_result/3" do
    setup do
      %{owner_id: owner_id} = scope = build(:scope)
      conversation = insert(:conversation, user_id: owner_id)
      call_id = "call_#{System.unique_integer([:positive])}"

      # Insert a tool_result row pre-marked as interrupted (the state the agent
      # leaves it in after the user is asked to approve/reject the call).
      {:ok, tr_msg} =
        Conversations.append_display_message(scope, conversation.id, %{
          message_type: "tool",
          content_type: "tool_result",
          content: %{
            "tool_call_id" => call_id,
            "name" => "deletion",
            "content" => "(pending)",
            "is_interrupt" => true
          }
        })

      {:ok, scope: scope, conversation: conversation, call_id: call_id, tr_msg: tr_msg}
    end

    test "fills in the result and clears is_interrupt", %{
      scope: scope,
      call_id: call_id
    } do
      assert {:ok, %DisplayMessage{} = updated} =
               Conversations.resolve_interrupted_tool_result(scope, call_id, "deleted: 4 rows")

      assert updated.content["is_interrupt"] == false
      assert updated.content["content"] == "deleted: 4 rows"
    end

    test "returns :not_found when no interrupted tool_result exists for that call_id", %{
      scope: scope
    } do
      assert {:error, :not_found} =
               Conversations.resolve_interrupted_tool_result(scope, "missing-id", "x")
    end

    test "rejects scope mismatch", %{call_id: call_id} do
      assert {:error, :not_found} =
               Conversations.resolve_interrupted_tool_result(build(:scope), call_id, "x")
    end
  end
end
