# RubyLLM Integration & Monkey Patching Strategy

This document explains how we integrate with RubyLLM and why we use monkey patching to enhance its tool execution capabilities.

## Overview

The Ruby Agents SDK builds on top of RubyLLM for LLM communication but needs to enhance tool execution for:
1. Thread-safe context injection
2. Parallel tool execution
3. Custom error handling

## The Challenge

RubyLLM's tool execution flow:
```ruby
# In RubyLLM::Chat
def handle_tool_calls(response)
  response.tool_calls.each do |tool_call|
    result = execute_tool(tool_call)  # Synchronous, no context
    add_tool_result(tool_call.id, result)
  end
  complete  # Recursive call
end
```

This creates several limitations:
- Tools execute sequentially (slow for multiple tools)
- No way to inject our ToolContext for thread safety
- No support for custom error handlers
- Tool execution is tightly coupled to the chat flow

## Our Solution: Two-Part Strategy

### Part 1: ContextualizedToolWrapper

We wrap each tool before passing it to RubyLLM:

```ruby
# Instead of passing tools directly:
chat = RubyLLM.chat(tools: [calculator_tool, weather_tool])

# We wrap them first:
wrapped_tools = tools.map { |t| ContextualizedToolWrapper.new(t, context) }
chat = RubyLLM.chat(tools: wrapped_tools)
```

The wrapper:
- Captures the RunContext for the current execution
- Creates a fresh ToolContext when RubyLLM calls the tool
- Ensures thread-safe execution with no shared state

### Part 2: Monkey Patch for Parallel Execution

We use `prepend` to enhance RubyLLM's tool execution:

```ruby
module AsyncToolExecution
  def handle_tool_calls(response, &block)
    if multiple_tools? && async_available?
      handle_tool_calls_async(response, &block)
    else
      super  # Fall back to original
    end
  end
end

RubyLLM::Chat.prepend(AsyncToolExecution)
```

## Why Monkey Patching?

We considered several alternatives:

### Alternative 1: Fork RubyLLM
- ❌ Maintenance burden
- ❌ Diverges from upstream
- ❌ Hard to track updates

### Alternative 2: Don't Use RubyLLM's Tools
- ❌ Lose automatic tool handling
- ❌ Have to parse tool calls manually
- ❌ Reimplement the entire flow

### Alternative 3: PR to RubyLLM
- ❌ May not align with their vision
- ❌ Long wait for acceptance
- ❌ Still need a solution now

### Our Choice: Minimal Monkey Patch
- ✅ Only override one method
- ✅ Can disable by not loading the file
- ✅ Easy to track RubyLLM changes
- ✅ Preserves all RubyLLM functionality

## Implementation Details

### The Wrapper Pattern

```ruby
class ContextualizedToolWrapper
  def initialize(tool, context_wrapper)
    @tool = tool
    @context_wrapper = context_wrapper
  end
  
  def execute(args)
    # RubyLLM calls this with just args
    tool_context = ToolContext.new(run_context: @context_wrapper)
    @tool.execute(tool_context, **args)  # We inject context
  end
  
  # Delegate everything else
  def method_missing(method, *args, &block)
    @tool.send(method, *args, &block)
  end
end
```

### The Monkey Patch

```ruby
module AsyncToolExecution
  def handle_tool_calls(response, &block)
    # Only parallelize if beneficial
    if defined?(Async) && response.tool_calls.size > 1
      Async do |task|
        # Execute tools in parallel
        response.tool_calls.map do |id, tool_call|
          task.async { execute_single_tool(tool_call, id) }
        end.map(&:wait)
      end
      complete(&block)
    else
      super  # Original behavior
    end
  end
end
```

## Maintenance Guide

### When Upgrading RubyLLM

1. Check if `handle_tool_calls` method signature changed:
   ```ruby
   # Look for changes in:
   RubyLLM::Chat#handle_tool_calls
   RubyLLM::Chat#execute_tool
   RubyLLM::Chat#add_tool_result
   ```

2. Verify our assumptions still hold:
   - Tools are stored in `@tools` hash
   - Tool execution happens in `execute_tool`
   - Results are added with `add_tool_result`

3. Run integration tests:
   ```bash
   bundle exec rspec spec/integration/ruby_llm_spec.rb
   ```

### If RubyLLM Changes Break Our Patch

1. **Minor changes**: Update the patch to match new signatures
2. **Major changes**: Consider if we still need the patch
3. **Complete rewrite**: Evaluate switching strategies

### Debugging

Enable debug logging:
```ruby
Agents.logger = Logger.new(STDOUT)
Agents.logger.level = Logger::DEBUG
```

Look for:
- `[Agents] Executing N tools in parallel`
- `[Agents] Tool execution failed: tool_name`

## Benefits of This Approach

1. **Performance**: Multiple tools execute in parallel
2. **Thread Safety**: Each execution gets isolated context
3. **Error Handling**: Tools can have custom error handlers
4. **Compatibility**: Falls back to sequential execution when needed
5. **Maintainability**: Changes isolated to two files

## Risks and Mitigations

### Risk: RubyLLM changes break our patch
**Mitigation**: Version lock in Gemfile, test suite, clear documentation

### Risk: Parallel execution causes issues
**Mitigation**: Only parallelize multiple tools, easy to disable

### Risk: Context wrapper overhead
**Mitigation**: Minimal object allocation, frozen instances

## Future Considerations

If RubyLLM adds native support for:
- Context injection
- Parallel execution  
- Custom error handlers

We can remove our enhancements and use their implementation.

## Testing

Always test with:
```ruby
# Single tool (should use original flow)
agent_with_one_tool.run("Calculate 2+2")

# Multiple tools (should parallelize)
agent_with_many_tools.run("Get weather and calculate tip")

# Error cases
agent_with_failing_tool.run("This will error")
```

## Conclusion

This approach gives us the best of both worlds:
- Leverage RubyLLM's proven LLM communication
- Add our thread-safe context management
- Optimize performance with parallel execution
- Maintain compatibility and upgradeability