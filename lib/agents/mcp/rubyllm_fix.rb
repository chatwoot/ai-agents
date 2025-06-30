# frozen_string_literal: true

# Universal RubyLLM parameter type conversion fix for all MCP tools and providers.
# This addresses type conversion issues across ALL LLM providers:
# 1. Ruby class types need conversion to JSON schema strings
# 2. Array parameters need proper "items" field for JSON Schema compliance

# Extend RubyLLM::Parameter to handle Ruby class types properly
if defined?(RubyLLM::Parameter)
  class RubyLLM::Parameter
    # Store the original type for reference
    alias_method :original_type, :type
    
    # Override type method to return JSON schema compatible type string
    def type
      raw_type = original_type
      return convert_ruby_type_to_json_schema(raw_type) if raw_type.is_a?(Class)
      raw_type
    end
    
    private
    
    # Convert Ruby class types to JSON schema type strings
    #
    # @param ruby_type [Class] Ruby type class
    # @return [String] JSON schema type string
    def convert_ruby_type_to_json_schema(ruby_type)
      return "string" if ruby_type == String
      return "integer" if ruby_type == Integer
      return "number" if ruby_type == Float
      return "boolean" if ruby_type == TrueClass || ruby_type == FalseClass
      return "array" if ruby_type == Array
      return "object" if ruby_type == Hash
      "string" # Default fallback
    end
  end
end

# Apply universal fix to all provider Tools modules
if defined?(RubyLLM::Providers)
  # Find all provider modules and apply the fix universally
  RubyLLM::Providers.constants.each do |provider_name|
    provider_module = RubyLLM::Providers.const_get(provider_name)
    
    # Check if this provider has a Tools module
    if provider_module.const_defined?(:Tools)
      tools_module = provider_module.const_get(:Tools)
      
      # Apply the fix to this provider's Tools module
      tools_module.module_eval do
        # Store original method if it exists
        if method_defined?(:param_schema)
          alias_method :orig_param_schema, :param_schema
        end
        
        # Enhanced param_schema for this provider
        def param_schema(param)
          schema = if respond_to?(:orig_param_schema)
                    orig_param_schema(param)
                  else
                    # Fallback schema generation
                    { type: param.type, description: param.description }.compact
                  end

          # Add default items schema for array types (JSON Schema requirement)
          if schema[:type] == "array" && !schema.key?(:items)
            schema[:items] = { type: "string" }
          end

          schema
        end
      end
    end
  end
end