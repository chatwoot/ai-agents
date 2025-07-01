# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::MCP::HttpTransport do
  let(:base_url) { "http://localhost:8000" }
  let(:headers) { { "Authorization" => "Bearer token123" } }
  let(:transport) { described_class.new(url: base_url, headers: headers) }

  # Helper method to transform keys recursively to strings (for JSON compatibility)
  def deep_transform_keys_to_strings(obj)
    case obj
    when Hash
      obj.transform_keys(&:to_s).transform_values { |v| deep_transform_keys_to_strings(v) }
    when Array
      obj.map { |v| deep_transform_keys_to_strings(v) }
    else
      obj
    end
  end

  describe "#initialize" do
    it "creates transport with URL and headers" do
      expect(transport.instance_variable_get(:@url)).to eq(base_url)
      # Check that our custom headers are present, along with default headers
      actual_headers = transport.instance_variable_get(:@headers)
      expect(actual_headers).to include("Authorization" => "Bearer token123")
      expect(actual_headers).to include("Accept" => "application/json")
      expect(actual_headers).to have_key("User-Agent")
    end

    it "accepts empty headers" do
      transport = described_class.new(url: base_url)
      actual_headers = transport.instance_variable_get(:@headers)
      # Should still have default headers even when no custom headers provided
      expect(actual_headers).to include("Accept" => "application/json")
      expect(actual_headers).to have_key("User-Agent")
    end

    it "handles trailing slash in URL" do
      transport = described_class.new(url: "http://localhost:8000/")
      expect(transport.instance_variable_get(:@url)).to eq("http://localhost:8000")
    end
  end

  describe "#call" do
    let(:mock_http) { instance_double(Net::HTTP) }
    let(:mock_response) { instance_double(Net::HTTPResponse) }

    before do
      allow(Net::HTTP).to receive(:new).and_return(mock_http)
      allow(mock_http).to receive(:use_ssl=)
      allow(mock_http).to receive(:read_timeout=)
      allow(mock_http).to receive(:open_timeout=)
      allow(mock_http).to receive(:write_timeout=)
      allow(mock_http).to receive(:request).and_return(mock_response)
      allow(mock_response).to receive(:code).and_return("200")
      allow(mock_response).to receive(:body).and_return('{"result": {"content": ["success"]}}')
      
      # Mock the health check endpoints used by connect()
      health_request = instance_double(Net::HTTP::Get)
      allow(Net::HTTP::Get).to receive(:new).and_return(health_request)
      allow(health_request).to receive(:[]=)
    end

    context "with successful requests" do
      it "sends HTTP POST requests with proper headers" do
        # Pre-connect the transport to avoid health check interference
        transport.instance_variable_set(:@connected, true)
        
        # The enhanced transport tries multiple endpoints, starting with GET /tools
        get_request_double = instance_double(Net::HTTP::Get)
        post_request_double = instance_double(Net::HTTP::Post)
        
        # Mock the first attempt (GET /tools) to fail
        allow(Net::HTTP::Get).to receive(:new).with("/tools").and_return(get_request_double)
        allow(get_request_double).to receive(:[]=)
        allow(mock_http).to receive(:request).with(get_request_double).and_raise(Errno::ECONNREFUSED)
        
        # Mock the fallback attempt (POST /mcp) to succeed
        allow(Net::HTTP::Post).to receive(:new).with("/mcp").and_return(post_request_double)
        allow(post_request_double).to receive(:[]=)
        allow(post_request_double).to receive(:body=)
        allow(mock_http).to receive(:request).with(post_request_double).and_return(mock_response)

        expect(Net::HTTP::Post).to receive(:new).with("/mcp")
        expect(post_request_double).to receive(:[]=).with("Content-Type", "application/json")
        expect(post_request_double).to receive(:[]=).with("Authorization", "Bearer token123")

        transport.call("tools/list", {})
      end

      it "sends request body as JSON" do
        # Pre-connect the transport to avoid health check interference
        transport.instance_variable_set(:@connected, true)
        
        # The enhanced transport tries multiple endpoints
        get_request_double = instance_double(Net::HTTP::Get)
        post_request_double = instance_double(Net::HTTP::Post)
        
        # Mock the first attempt (GET /tools) to fail
        allow(Net::HTTP::Get).to receive(:new).with("/tools").and_return(get_request_double)
        allow(get_request_double).to receive(:[]=)
        allow(mock_http).to receive(:request).with(get_request_double).and_raise(Errno::ECONNREFUSED)
        
        # Mock the fallback attempt (POST /mcp) to succeed
        allow(Net::HTTP::Post).to receive(:new).with("/mcp").and_return(post_request_double)
        allow(post_request_double).to receive(:[]=)
        allow(mock_http).to receive(:request).with(post_request_double).and_return(mock_response)

        # Check that the body contains the right JSON structure, regardless of field order
        expect(post_request_double).to receive(:body=) do |body|
          request = JSON.parse(body)
          expect(request).to include({
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/list",
            "params" => {}
          })
        end

        transport.call("tools/list", {})
      end

      it "parses JSON response correctly" do
        result = transport.call("tools/list", {})
        expect(result).to eq({ "content" => ["success"] })
      end

      it "handles HTTPS URLs" do
        https_transport = described_class.new(url: "https://api.example.com")

        expect(Net::HTTP).to receive(:new).with("api.example.com", 443)
        expect(mock_http).to receive(:use_ssl=).with(true)
        expect(mock_http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER).at_least(:once)

        https_transport.call("tools/list", {})
      end

      it "includes custom headers in requests" do
        custom_headers = {
          "Authorization" => "Bearer token123",
          "X-Custom-Header" => "custom-value"
        }
        transport = described_class.new(url: base_url, headers: custom_headers)
        
        # Pre-connect the transport to avoid health check interference
        transport.instance_variable_set(:@connected, true)

        # Mock HTTP client creation
        custom_mock_http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(custom_mock_http)
        allow(custom_mock_http).to receive(:use_ssl=)
        allow(custom_mock_http).to receive(:read_timeout=)
        allow(custom_mock_http).to receive(:open_timeout=)
        allow(custom_mock_http).to receive(:write_timeout=)

        # The enhanced transport tries multiple endpoints
        get_request_double = instance_double(Net::HTTP::Get)
        post_request_double = instance_double(Net::HTTP::Post)
        
        # Mock the first attempt (GET /tools) to fail
        allow(Net::HTTP::Get).to receive(:new).with("/tools").and_return(get_request_double)
        allow(get_request_double).to receive(:[]=)
        allow(custom_mock_http).to receive(:request).with(get_request_double).and_raise(Errno::ECONNREFUSED)
        
        # Mock the fallback attempt (POST /mcp) to succeed
        allow(Net::HTTP::Post).to receive(:new).with("/mcp").and_return(post_request_double)
        allow(post_request_double).to receive(:body=)
        
        # Mock successful response
        custom_mock_response = instance_double(Net::HTTPResponse)
        allow(custom_mock_response).to receive(:code).and_return("200")
        allow(custom_mock_response).to receive(:body).and_return('{"result": {"content": ["success"]}}')
        allow(custom_mock_http).to receive(:request).with(post_request_double).and_return(custom_mock_response)

        expect(post_request_double).to receive(:[]=).with("Content-Type", "application/json")
        expect(post_request_double).to receive(:[]=).with("Authorization", "Bearer token123")
        expect(post_request_double).to receive(:[]=).with("X-Custom-Header", "custom-value")
        expect(post_request_double).to receive(:[]=).with("Accept", "application/json")
        expect(post_request_double).to receive(:[]=).with("User-Agent", anything)

        transport.call("tools/list", {})
      end
    end

    context "error handling" do
      it "handles HTTP error responses" do
        allow(mock_response).to receive(:code).and_return("500")
        allow(mock_response).to receive(:message).and_return("Internal Server Error")
        allow(mock_response).to receive(:body).and_return("Server Error")

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /HTTP 500.*Internal Server Error/)
      end

      it "handles network connection errors" do
        allow(mock_http).to receive(:request).and_raise(Errno::ECONNREFUSED, "Connection refused")

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Failed to connect.*Connection refused/)
      end

      it "handles timeout errors" do
        allow(mock_http).to receive(:request).and_raise(Timeout::Error)

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Request timeout/)
      end

      it "handles invalid JSON responses" do
        allow(mock_response).to receive(:body).and_return("invalid json")

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ProtocolError, /Invalid JSON response/)
      end

      it "handles empty responses" do
        allow(mock_response).to receive(:body).and_return("")

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ProtocolError, /Empty response/)
      end

      it "handles MCP error responses" do
        error_response = {
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => {
            "code" => -32_602,
            "message" => "Invalid params"
          }
        }
        allow(mock_response).to receive(:body).and_return(error_response.to_json)

        expect do
          transport.call("tools/call", { invalid: "params" })
        end.to raise_error(Agents::MCP::ServerError, /Invalid params/)
      end
    end

    context "request formatting" do
      it "generates unique request IDs" do
        request_ids = []
        
        # Pre-connect the transport to avoid health check interference
        transport.instance_variable_set(:@connected, true)
        
        # The enhanced transport tries multiple endpoints
        get_request_double = instance_double(Net::HTTP::Get)
        post_request_double = instance_double(Net::HTTP::Post)
        
        # Mock the first attempt (GET /tools) to fail
        allow(Net::HTTP::Get).to receive(:new).with("/tools").and_return(get_request_double)
        allow(get_request_double).to receive(:[]=)
        allow(mock_http).to receive(:request).with(get_request_double).and_raise(Errno::ECONNREFUSED)
        
        # Mock the fallback attempt (POST /mcp) to succeed
        allow(Net::HTTP::Post).to receive(:new).with("/mcp").and_return(post_request_double)
        allow(post_request_double).to receive(:[]=)
        allow(mock_http).to receive(:request).with(post_request_double).and_return(mock_response)

        allow(post_request_double).to receive(:body=) do |body|
          request = JSON.parse(body)
          request_ids << request["id"]
        end

        # Make multiple calls
        3.times { transport.call("tools/list", {}) }

        expect(request_ids).to have_attributes(size: 3)
        expect(request_ids.uniq).to eq(request_ids) # All unique
      end

      it "formats JSON-RPC 2.0 correctly" do
        request_double = instance_double(Net::HTTP::Post)
        allow(Net::HTTP::Post).to receive(:new).and_return(request_double)
        allow(request_double).to receive(:[]=)

        allow(request_double).to receive(:body=) do |body|
          request = JSON.parse(body)
          expect(request).to include({
                                       "jsonrpc" => "2.0",
                                       "method" => "tools/list",
                                       "params" => {}
                                     })
          expect(request["id"]).to be_a(Integer)
        end

        transport.call("tools/list", {})
      end

      it "includes parameters in request" do
        params = { name: "test_tool", arguments: { key: "value" } }
        request_double = instance_double(Net::HTTP::Post)
        allow(Net::HTTP::Post).to receive(:new).and_return(request_double)
        allow(request_double).to receive(:[]=)

        allow(request_double).to receive(:body=) do |body|
          request = JSON.parse(body)
          # JSON parsing converts all symbols to strings, so we need to deep transform
          expected_params = deep_transform_keys_to_strings(params)
          expect(request["params"]).to eq(expected_params)
        end

        transport.call("tools/call", params)
      end
    end

    context "response parsing" do
      it "extracts result from JSON-RPC response" do
        result_data = { "tools" => %w[tool1 tool2] }
        response = {
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => result_data
        }
        allow(mock_response).to receive(:body).and_return(response.to_json)

        result = transport.call("tools/list", {})
        expect(result).to eq(result_data)
      end

      it "handles responses with no result field" do
        # Pre-connect the transport to avoid health check interference
        transport.instance_variable_set(:@connected, true)
        
        # The enhanced transport tries multiple endpoints
        get_request_double = instance_double(Net::HTTP::Get)
        post_request_double = instance_double(Net::HTTP::Post)
        
        # Mock the first attempt (GET /tools) to fail
        allow(Net::HTTP::Get).to receive(:new).with("/tools").and_return(get_request_double)
        allow(get_request_double).to receive(:[]=)
        allow(mock_http).to receive(:request).with(get_request_double).and_raise(Errno::ECONNREFUSED)
        
        # Mock the fallback attempt (POST /mcp) to succeed with no result
        allow(Net::HTTP::Post).to receive(:new).with("/mcp").and_return(post_request_double)
        allow(post_request_double).to receive(:[]=)
        allow(post_request_double).to receive(:body=)
        
        response = {
          "jsonrpc" => "2.0",
          "id" => 1
        }
        
        custom_mock_response = instance_double(Net::HTTPResponse)
        allow(custom_mock_response).to receive(:code).and_return("200")
        allow(custom_mock_response).to receive(:body).and_return(response.to_json)
        allow(mock_http).to receive(:request).with(post_request_double).and_return(custom_mock_response)

        result = transport.call("tools/list", {})
        expect(result).to be_nil
      end
    end
  end

  describe "#close" do
    it "exists as a no-op method" do
      expect { transport.close }.not_to raise_error
    end
  end

  describe "thread safety" do
    it "handles concurrent requests safely" do
      # Mock successful HTTP responses
      mock_http = instance_double(Net::HTTP)
      mock_response = instance_double(Net::HTTPResponse)

      allow(Net::HTTP).to receive(:new).and_return(mock_http)
      allow(mock_http).to receive(:use_ssl=)
      allow(mock_http).to receive(:read_timeout=)
      allow(mock_http).to receive(:open_timeout=)
      allow(mock_http).to receive(:request).and_return(mock_response)
      allow(mock_response).to receive(:code).and_return("200")
      allow(mock_response).to receive(:body).and_return('{"result": {}}')

      threads = []
      results = []
      mutex = Mutex.new

      # Create multiple concurrent requests
      5.times do |i|
        threads << Thread.new do
          result = transport.call("tools/list", { index: i })
          mutex.synchronize { results << result }
        end
      end

      threads.each(&:join)

      expect(results).to have_attributes(size: 5)
    end
  end

  describe "URL handling" do
    let(:mock_http) { instance_double(Net::HTTP) }
    let(:mock_response) { instance_double(Net::HTTPResponse) }
    
    before do
      # Mock the complete HTTP chain for URL handling tests
      mock_request = instance_double(Net::HTTP::Post)

      allow(Net::HTTP).to receive(:new).and_return(mock_http)
      allow(mock_http).to receive(:use_ssl=)
      allow(mock_http).to receive(:read_timeout=)
      allow(mock_http).to receive(:open_timeout=)
      allow(mock_http).to receive(:write_timeout=)
      allow(mock_http).to receive(:request).and_return(mock_response)
      allow(mock_response).to receive(:code).and_return("200")
      allow(mock_response).to receive(:body).and_return('{"result": {}}')

      allow(mock_request).to receive(:[]=)
      allow(mock_request).to receive(:body=)
      allow(Net::HTTP::Post).to receive(:new).and_return(mock_request)
      
      # Mock the health check endpoints used by connect()
      health_request = instance_double(Net::HTTP::Get)
      allow(Net::HTTP::Get).to receive(:new).and_return(health_request)
      allow(health_request).to receive(:[]=)
    end

    it "constructs proper endpoint URLs" do
      # Pre-connect the transport to avoid health check interference
      transport.instance_variable_set(:@connected, true)
      
      # The enhanced transport tries /tools first, which fails, then falls back to /mcp
      get_request_double = instance_double(Net::HTTP::Get)
      post_request_double = instance_double(Net::HTTP::Post)
      
      # Mock the first attempt (GET /tools) to fail
      expect(Net::HTTP::Get).to receive(:new).with("/tools").and_return(get_request_double)
      allow(get_request_double).to receive(:[]=)
      allow(mock_http).to receive(:request).with(get_request_double).and_raise(Errno::ECONNREFUSED)
      
      # Mock the fallback attempt (POST /mcp) to succeed
      expect(Net::HTTP::Post).to receive(:new).with("/mcp").and_return(post_request_double)
      allow(post_request_double).to receive(:[]=)
      allow(post_request_double).to receive(:body=)
      
      transport.call("tools/list", {})
    end

    it "handles base URLs with paths" do
      transport = described_class.new(url: "http://localhost:8000/api/v1")
      
      # Pre-connect the transport to avoid health check interference
      transport.instance_variable_set(:@connected, true)
      
      # Mock HTTP client creation
      custom_mock_http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(custom_mock_http)
      allow(custom_mock_http).to receive(:use_ssl=)
      allow(custom_mock_http).to receive(:read_timeout=)
      allow(custom_mock_http).to receive(:open_timeout=)
      allow(custom_mock_http).to receive(:write_timeout=)
      
      # The enhanced transport tries /api/v1/tools first, which fails, then falls back to /api/v1/mcp
      get_request_double = instance_double(Net::HTTP::Get)
      post_request_double = instance_double(Net::HTTP::Post)
      
      # Mock the first attempt (GET /api/v1/tools) to fail
      expect(Net::HTTP::Get).to receive(:new).with("/api/v1/tools").and_return(get_request_double)
      allow(get_request_double).to receive(:[]=)
      allow(custom_mock_http).to receive(:request).with(get_request_double).and_raise(Errno::ECONNREFUSED)
      
      # Mock the fallback attempt (POST /api/v1/mcp) to succeed
      expect(Net::HTTP::Post).to receive(:new).with("/api/v1/mcp").and_return(post_request_double)
      allow(post_request_double).to receive(:[]=)
      allow(post_request_double).to receive(:body=)
      
      # Mock successful response
      custom_mock_response = instance_double(Net::HTTPResponse)
      allow(custom_mock_response).to receive(:code).and_return("200")
      allow(custom_mock_response).to receive(:body).and_return('{"result": {}}')
      allow(custom_mock_http).to receive(:request).with(post_request_double).and_return(custom_mock_response)
      
      transport.call("tools/list", {})
    end

    it "handles base URLs with trailing slashes" do
      transport = described_class.new(url: "http://localhost:8000/api/")
      
      # Pre-connect the transport to avoid health check interference
      transport.instance_variable_set(:@connected, true)
      
      # Mock HTTP client creation
      custom_mock_http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(custom_mock_http)
      allow(custom_mock_http).to receive(:use_ssl=)
      allow(custom_mock_http).to receive(:read_timeout=)
      allow(custom_mock_http).to receive(:open_timeout=)
      allow(custom_mock_http).to receive(:write_timeout=)
      
      # The enhanced transport tries /api/tools first, which fails, then falls back to /api/mcp
      get_request_double = instance_double(Net::HTTP::Get)
      post_request_double = instance_double(Net::HTTP::Post)
      
      # Mock the first attempt (GET /api/tools) to fail
      expect(Net::HTTP::Get).to receive(:new).with("/api/tools").and_return(get_request_double)
      allow(get_request_double).to receive(:[]=)
      allow(custom_mock_http).to receive(:request).with(get_request_double).and_raise(Errno::ECONNREFUSED)
      
      # Mock the fallback attempt (POST /api/mcp) to succeed
      expect(Net::HTTP::Post).to receive(:new).with("/api/mcp").and_return(post_request_double)
      allow(post_request_double).to receive(:[]=)
      allow(post_request_double).to receive(:body=)
      
      # Mock successful response
      custom_mock_response = instance_double(Net::HTTPResponse)
      allow(custom_mock_response).to receive(:code).and_return("200")
      allow(custom_mock_response).to receive(:body).and_return('{"result": {}}')
      allow(custom_mock_http).to receive(:request).with(post_request_double).and_return(custom_mock_response)
      
      transport.call("tools/list", {})
    end
  end
end
