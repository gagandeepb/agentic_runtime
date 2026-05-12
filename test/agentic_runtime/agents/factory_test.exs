defmodule AgenticRuntime.Agents.FactoryTest do
  use ExUnit.Case, async: true

  alias AgenticRuntime.Agents.Factory

  defp build_model do
    AgenticRuntime.build_anthropic_model_config("claude-opus-4-7", "test-key", [])
  end

  describe "create_agent/1" do
    test "produces an agent whose middleware stack matches the documented order" do
      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-test",
                 model_config: build_model(),
                 base_system_prompt: "Be helpful."
               )

      modules = Enum.map(agent.middleware, & &1.module)

      # DISABLED (plan: valiant-twirling-crown): FileSystem + AskUserQuestion removed from stack
      expected = [
        Sagents.Middleware.TodoList,
        Sagents.Middleware.ConversationTitle,
        # Sagents.Middleware.FileSystem,
        Sagents.Middleware.SubAgent,
        Sagents.Middleware.Summarization,
        Sagents.Middleware.PatchToolCalls
        # Sagents.Middleware.AskUserQuestion
      ]

      assert modules == expected
    end

    # DISABLED (plan: valiant-twirling-crown): HumanInTheLoop append removed from factory
    @tag :skip
    test "appends HumanInTheLoop when :interrupt_on is provided" do
      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-hitl",
                 model_config: build_model(),
                 base_system_prompt: "x",
                 interrupt_on: %{"delete_file" => true}
               )

      modules = Enum.map(agent.middleware, & &1.module)
      assert Sagents.Middleware.HumanInTheLoop in modules
    end

    test "does not append HumanInTheLoop when :interrupt_on is nil" do
      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-no-hitl",
                 model_config: build_model(),
                 base_system_prompt: "x"
               )

      modules = Enum.map(agent.middleware, & &1.module)
      refute Sagents.Middleware.HumanInTheLoop in modules
    end

    test "passes :tool_context through to the agent struct" do
      ctx = %{user_id: 42, tenant: "acme"}

      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-ctx",
                 model_config: build_model(),
                 base_system_prompt: "x",
                 tool_context: ctx
               )

      assert agent.tool_context == ctx
    end

    test "raises KeyError when :agent_id is missing" do
      assert_raise KeyError, fn ->
        Factory.create_agent(model_config: build_model(), base_system_prompt: "x")
      end
    end

    test "raises KeyError when :model_config is missing" do
      assert_raise KeyError, fn ->
        Factory.create_agent(agent_id: "x", base_system_prompt: "x")
      end
    end

    test "raises KeyError when :base_system_prompt is missing" do
      assert_raise KeyError, fn ->
        Factory.create_agent(agent_id: "x", model_config: build_model())
      end
    end
  end

  describe "model config builders" do
    test "build_anthropic_model_config sets model, key, stream, and thinking" do
      m = Factory.build_anthropic_model_config("claude-opus-4-7", "k", [])
      assert m.model == "claude-opus-4-7"
      assert m.api_key == "k"
      assert m.stream == true
      assert m.thinking == %{type: "enabled"}
    end

    test "build_openai_model_config sets model, key, and stream" do
      m = Factory.build_openai_model_config("gpt-5", "k")
      assert m.model == "gpt-5"
      assert m.api_key == "k"
      assert m.stream == true
    end

    test "build_googleai_model_config sets model, key, and stream" do
      m = Factory.build_googleai_model_config("gemini-2", "k")
      assert m.model == "gemini-2"
      assert m.api_key == "k"
      assert m.stream == true
    end
  end
end
