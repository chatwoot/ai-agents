# frozen_string_literal: true

# The run context holds the context and other information like token usage
# for a specific run only
class Agents::RunContext
  attr_reader :context, :usage

  def initialize(context, usage)
    @context = context
    @usage = Usage.new
  end

  # This is very rudimentary usage reporting
  # We can use this further for billing purposes, but is not a replacement for tracing
  class Usage
    attr_accessor :input_tokens, :output_tokens, :total_tokens

    def initialize
      @input_tokens = 0
      @output_tokens = 0
      @total_tokens = 0
    end

    def add(usage)
      @input_tokens += usage.input_tokens || 0
      @output_tokens += usage.output_tokens || 0
      @total_tokens += usage.total_tokens || 0
    end
  end

end
