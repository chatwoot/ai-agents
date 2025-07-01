# frozen_string_literal: true

require "set"

module Agents
  module MCP
    # Dynamic tool class that represents tools provided by MCP servers.
    # These tools are generated at runtime based on the tool definitions
    # returned by the MCP server, creating a seamless interface between
    # the agent system and external MCP capabilities.
    #
    # Tools are created dynamically by parsing the MCP server's tool schema
    # and generating appropriate Ruby classes with proper parameter definitions.
    #
    # @example Usage (typically handled automatically by MCP::Client)
    #   tool_data = {
    #     "name" => "read_file",
    #     "description" => "Read the contents of a file",
    #     "inputSchema" => {
    #       "type" => "object",
    #       "properties" => {
    #         "path" => { "type" => "string", "description" => "File path" }
    #       },
    #       "required" => ["path"]
    #     }
    #   }
    #
    #   tool = Tool.create_from_mcp_data(tool_data, client: mcp_client)
    #   # Tool can now be used like any other Agents::Tool
    class Tool < Agents::Tool
      # Create a dynamic tool instance from MCP server tool data
      #
      # @param tool_data [Hash] Tool definition from MCP server
      # @param client [Agents::MCP::Client] The MCP client to use for calls
      # @return [Agents::MCP::Tool] New tool instance
      # @raise [ProtocolError] If tool schema is invalid
      def self.create_from_mcp_data(tool_data, client:)
        validate_tool_data(tool_data)

        tool_name = tool_data["name"]
        tool_description = tool_data["description"] || "MCP tool #{tool_name}"
        input_schema = normalize_input_schema(tool_data["inputSchema"])

        create_dynamic_tool_class(tool_name, tool_description, input_schema, client)
      end

      private_class_method def self.validate_tool_data(tool_data)
        raise ProtocolError, "Tool missing name" unless tool_data["name"]

        input_schema = tool_data["inputSchema"]
        return unless input_schema && !input_schema.is_a?(Hash)

        raise ProtocolError, "Invalid input schema"
      end

      private_class_method def self.normalize_input_schema(schema)
        return {} unless schema.is_a?(Hash)

        fix_array_schemas(schema)
      end

      def self.create_dynamic_tool_class(name, description, schema, client)
        tool_class = Class.new(self) do
          description description
        end

        configure_tool_parameters(tool_class, schema)
        configure_tool_methods(tool_class, name, client)

        tool_class.new
      end

      private_class_method def self.configure_tool_parameters(tool_class, schema)
        properties = schema["properties"] || {}
        required_params = Set.new(schema["required"] || [])

        properties.each do |param_name, param_def|
          param_desc = param_def["description"] || "Parameter for #{param_name}"
          is_required = required_params.include?(param_name)
          ruby_type = convert_json_type_to_ruby_type(param_def["type"])

          tool_class.param param_name.to_sym, ruby_type, param_desc, required: is_required
        end
      end

      private_class_method def self.configure_tool_methods(tool_class, name, client)
        store_mcp_data(tool_class, name, client)
        define_accessor_methods(tool_class)
        define_execution_method(tool_class, name)
        define_inspection_method(tool_class, name)
        configure_class_name(tool_class, name)
      end

      private_class_method def self.store_mcp_data(tool_class, name, client)
        tool_class.class_variable_set(:@@mcp_client, client)
        tool_class.class_variable_set(:@@mcp_tool_name, name)
      end

      private_class_method def self.define_accessor_methods(tool_class)
        tool_class.define_method(:mcp_client) do
          self.class.class_variable_get(:@@mcp_client)
        end

        tool_class.define_method(:mcp_tool_name) do
          self.class.class_variable_get(:@@mcp_tool_name)
        end
      end

      private_class_method def self.define_execution_method(tool_class, name)
        tool_class.define_method(:perform) do |_tool_context, **args|
          string_args = args.transform_keys(&:to_s)

          begin
            mcp_client = self.class.class_variable_get(:@@mcp_client)
            mcp_tool_name = self.class.class_variable_get(:@@mcp_tool_name)
            result = mcp_client.call_tool(mcp_tool_name, string_args)
            result.to_s
          rescue StandardError => e
            "Error calling MCP tool #{name}: #{e.message}"
          end
        end
      end

      private_class_method def self.define_inspection_method(tool_class, name)
        tool_class.define_method(:inspect) do
          "#<MCPTool(#{name}):#{object_id}>"
        end
      end

      private_class_method def self.configure_class_name(tool_class, name)
        tool_class.define_singleton_method(:name) { name }
      end

      private_class_method :create_dynamic_tool_class

      # Fix array schemas that are missing items specifications
      #
      # @param schema [Hash] JSON schema to fix
      # @return [Hash] Fixed schema with proper array items
      def self.fix_array_schemas(schema)
        return schema unless schema.is_a?(Hash)

        fixed_schema = schema.dup

        fixed_schema["items"] = { "type" => "string" } if array_schema_missing_items?(schema)

        fix_nested_schemas(fixed_schema, schema)
        fixed_schema
      end

      private_class_method def self.array_schema_missing_items?(schema)
        schema["type"] == "array" && !schema["items"]
      end

      private_class_method def self.fix_nested_schemas(fixed_schema, original_schema)
        return unless original_schema["properties"]

        fixed_schema["properties"] = {}
        original_schema["properties"].each do |prop_name, prop_def|
          fixed_schema["properties"][prop_name] = fix_array_schemas(prop_def)
        end
      end

      # Convert JSON schema types to Ruby types
      #
      # @param json_type [String] JSON schema type
      # @return [Class] Corresponding Ruby type
      def self.convert_json_type_to_ruby_type(json_type)
        case json_type&.downcase
        when "string" then String
        when "integer" then Integer
        when "number" then Float
        when "boolean" then TrueClass
        when "array" then Array
        when "object" then Hash
        else String
        end
      end

      private_class_method :convert_json_type_to_ruby_type

      # Map JSON schema types to RubyLLM parameter type strings
      #
      # @param json_type [String] JSON schema type
      # @return [String] Corresponding RubyLLM type string
      # @deprecated This method is kept for backward compatibility
      def self.map_json_type_to_ruby_llm_type(json_type)
        normalized_type = json_type.to_s.downcase

        case normalized_type
        when "string" then "string"
        when "integer" then "integer"
        when "number" then "number"
        when "boolean" then "boolean"
        when "array" then "array"
        when "object" then "object"
        else "string"
        end
      end

      # Convert MCP parameter definition to valid RubyLLM JSON schema
      # This layer ensures compatibility with both old and new schema formats
      # and creates complete, valid schemas that RubyLLM will accept
      #
      # @param param_def [Hash] Parameter definition from MCP server
      # @return [Hash] Valid JSON schema for RubyLLM
      def self.convert_to_valid_schema(param_def)
        param_type = param_def["type"]&.downcase

        case param_type
        when "array"
          convert_array_schema(param_def)
        when "object"
          convert_object_schema(param_def)
        when "string", "integer", "number", "boolean"
          { "type" => param_type }
        else
          { "type" => "string" }
        end
      end

      private_class_method def self.convert_array_schema(param_def)
        items_schema = if param_def["items"]
                         convert_to_valid_schema(param_def["items"])
                       else
                         { "type" => "string" }
                       end

        {
          "type" => "array",
          "items" => items_schema
        }
      end

      private_class_method def self.convert_object_schema(param_def)
        properties = param_def["properties"] || {}
        required = param_def["required"] || []

        validated_properties = {}
        properties.each do |prop_name, prop_def|
          validated_properties[prop_name] = convert_to_valid_schema(prop_def)
        end

        {
          "type" => "object",
          "properties" => validated_properties,
          "required" => required
        }
      end
    end
  end
end
