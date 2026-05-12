defmodule AgenticRuntimeTest do
  use ExUnit.Case, async: true

  import Mox

  alias AgenticRuntime.Agents.ServerAdapter
  alias AgenticRuntime.Agents.SupervisorAdapter

  setup :verify_on_exit!

  describe "build_anthropic_model_config/3" do
    test "returns a ChatAnthropic struct with stream + thinking enabled by default" do
      builder_fn_without_opts = fn model_name, api_key ->
        AgenticRuntime.build_anthropic_model_config(model_name, api_key)
      end

      builder_fn_with_empty_opts = fn model_name, api_key ->
        AgenticRuntime.build_anthropic_model_config(model_name, api_key, [])
      end

      for builder_fn <- [builder_fn_without_opts, builder_fn_with_empty_opts] do
        model = builder_fn.("claude-opus-4-7", "test-key")

        assert %LangChain.ChatModels.ChatAnthropic{} = model
        assert model.model == "claude-opus-4-7"
        assert model.api_key == "test-key"
        assert model.stream == true
        assert model.thinking == %{type: "enabled"}
      end
    end

    test "respects :thinking opt override" do
      model =
        AgenticRuntime.build_anthropic_model_config("claude-opus-4-7", "k",
          thinking: %{type: "disabled"}
        )

      assert model.thinking == %{type: "disabled"}
    end
  end

  describe "build_openai_model_config/2" do
    test "returns a ChatOpenAI struct with streaming enabled" do
      model = AgenticRuntime.build_openai_model_config("gpt-5", "test-key")

      assert %LangChain.ChatModels.ChatOpenAI{} = model
      assert model.model == "gpt-5"
      assert model.api_key == "test-key"
      assert model.stream == true
    end
  end

  describe "build_googleai_model_config/2" do
    test "returns a ChatGoogleAI struct with streaming enabled" do
      model = AgenticRuntime.build_googleai_model_config("gemini-2.0", "test-key")

      assert %LangChain.ChatModels.ChatGoogleAI{} = model
      assert model.model == "gemini-2.0"
      assert model.api_key == "test-key"
      assert model.stream == true
    end
  end

  describe "create_agent/1" do
    setup do
      model = AgenticRuntime.build_anthropic_model_config("claude-opus-4-7", "test-key", [])
      {:ok, model: model}
    end

    test "returns {:ok, agent} with the full middleware stack composed", %{model: model} do
      assert {:ok, agent} =
               AgenticRuntime.create_agent(
                 agent_id: "test-agent",
                 model_config: model,
                 base_system_prompt: "You are helpful."
               )

      modules = Enum.map(agent.middleware, & &1.module)

      for expected <- [
            Sagents.Middleware.TodoList,
            Sagents.Middleware.ConversationTitle,
            Sagents.Middleware.FileSystem,
            Sagents.Middleware.SubAgent,
            Sagents.Middleware.Summarization,
            Sagents.Middleware.PatchToolCalls,
            Sagents.Middleware.AskUserQuestion
          ] do
        assert expected in modules, "expected #{inspect(expected)} in middleware stack"
      end

      assert agent.agent_id == "test-agent"
    end

    test "raises on missing required :agent_id", %{model: model} do
      assert_raise KeyError, fn ->
        AgenticRuntime.create_agent(model_config: model, base_system_prompt: "x")
      end
    end

    test "raises on missing required :model_config" do
      assert_raise KeyError, fn ->
        AgenticRuntime.create_agent(agent_id: "x", base_system_prompt: "x")
      end
    end

    test "raises on missing required :base_system_prompt", %{model: model} do
      assert_raise KeyError, fn ->
        AgenticRuntime.create_agent(agent_id: "x", model_config: model)
      end
    end

    test "propagates :scope through to the agent struct", %{model: model} do
      scope = %AgenticRuntime.Factories.Scope{owner_id: 99}

      assert {:ok, agent} =
               AgenticRuntime.create_agent(
                 agent_id: "scoped-agent",
                 model_config: model,
                 base_system_prompt: "x",
                 scope: scope
               )

      assert agent.scope == scope
    end
  end

  describe "build_new_user_message!/1" do
    test "returns a LangChain.Message with role :user and the supplied text" do
      msg = AgenticRuntime.build_new_user_message!("hello")
      assert %LangChain.Message{role: :user} = msg
      assert [%LangChain.Message.ContentPart{type: :text, content: "hello"}] = msg.content
    end
  end

  describe "add_message/2" do
    test "calls ServerAdapter.add_message/2 with the agent_id and message" do
      message = LangChain.Message.new_user!("hi")

      expect(ServerAdapter.Mock, :add_message, fn "agent-1", ^message -> :ok end)

      assert :ok = AgenticRuntime.add_message("agent-1", message)
    end
  end

  describe "cancel_agent_execution/1" do
    test "calls ServerAdapter.cancel/1 with the agent_id" do
      expect(ServerAdapter.Mock, :cancel, fn "agent-2" -> :ok end)
      assert :ok = AgenticRuntime.cancel_agent_execution("agent-2")
    end
  end

  describe "new_tool!/1" do
    test "returns a LangChain.Function with the given name" do
      tool =
        AgenticRuntime.new_tool!(%{
          name: "echo",
          description: "echoes",
          function: fn _args, _context -> {:ok, "ok"} end
        })

      assert %LangChain.Function{name: "echo"} = tool
    end
  end

  describe "start_runtime/1" do
    test "delegates to SupervisorAdapter.child_spec/1" do
      expect(SupervisorAdapter.Mock, :child_spec, fn opts ->
        %{id: opts[:id], start: {__MODULE__, :noop, [opts]}}
      end)

      spec = AgenticRuntime.start_runtime(id: :test_runtime)
      assert spec.id == :test_runtime
    end
  end
end
