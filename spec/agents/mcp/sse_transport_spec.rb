# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::MCP::SseTransport do
  let(:url) { "http://localhost:8000" }
  let(:headers) { { "Authorization" => "Bearer token" } }
  let(:transport) { described_class.new(url: url, headers: headers) }

  describe "#initialize" do
    it "creates transport with URL and headers" do
      expect(transport.base_url).to eq(url)
      expect(transport.headers).to include("Authorization" => "Bearer token")
      expect(transport.headers).to include("Accept" => "text/event-stream, application/json")
      expect(transport.headers).to include("User-Agent")
    end

    it "accepts security options" do
      secure_transport = described_class.new(
        url: url,
        verify_ssl: false,
        allowed_origins: ["http://localhost:8000"]
      )

      expect(secure_transport.verify_ssl).to be false
      expect(secure_transport.allowed_origins).to eq(["http://localhost:8000"])
    end

    it "validates URL scheme" do
      expect do
        described_class.new(url: "ftp://example.com")
      end.to raise_error(Agents::MCP::ConnectionError, /Unsupported URL scheme/)
    end

    it "validates allowed origins when specified" do
      expect do
        described_class.new(
          url: "http://localhost:3000",
          allowed_origins: ["http://localhost:8000"]
        )
      end.to raise_error(Agents::MCP::ConnectionError, /not in allowed origins list/)
    end
  end

  describe "#connected?" do
    it "returns false when not connected" do
      expect(transport.connected?).to be false
    end
  end

  describe "message handlers" do
    it "allows adding message handlers" do
      handler_called = false
      transport.on_message { |_msg| handler_called = true }

      # Simulate message handling
      transport.send(:process_sse_line, 'data: {"test": "message"}')
      expect(handler_called).to be true
    end

    it "allows adding error handlers" do
      handler_called = false
      transport.on_error { |_err| handler_called = true }

      # Check that the handler was stored
      expect(transport.instance_variable_get(:@error_handlers).length).to eq(1)
    end

    it "allows adding close handlers" do
      handler_called = false
      transport.on_close { handler_called = true }

      # Check that the handler was stored
      expect(transport.instance_variable_get(:@close_handlers).length).to eq(1)
    end
  end

  describe "#disconnect" do
    it "sets connected state to false" do
      transport.disconnect
      expect(transport.connected?).to be false
    end

    it "stops SSE thread if running" do
      # Create a mock thread
      mock_thread = double("Thread", alive?: true, kill: nil, join: nil)
      transport.instance_variable_set(:@sse_thread, mock_thread)

      expect(mock_thread).to receive(:kill)
      expect(mock_thread).to receive(:join).with(5)

      transport.disconnect
    end
  end

  describe "private methods" do
    describe "#deep_transform_keys" do
      it "transforms hash keys to strings recursively" do
        input = { symbol: { nested: "value" }, array: [{ item: "test" }] }
        result = transport.send(:deep_transform_keys, input)

        expect(result).to eq({
                               "symbol" => { "nested" => "value" },
                               "array" => [{ "item" => "test" }]
                             })
      end
    end

    describe "#process_sse_line" do
      it "processes data lines" do
        handler_called = false
        received_message = nil

        transport.on_message do |msg|
          handler_called = true
          received_message = msg
        end

        transport.send(:process_sse_line, 'data: {"test": "value"}')

        expect(handler_called).to be true
        expect(received_message).to eq({ "test" => "value" })
      end

      it "ignores comment lines" do
        handler_called = false
        transport.on_message { |_msg| handler_called = true }

        transport.send(:process_sse_line, ": this is a comment")
        expect(handler_called).to be false
      end

      it "ignores empty lines" do
        handler_called = false
        transport.on_message { |_msg| handler_called = true }

        transport.send(:process_sse_line, "")
        expect(handler_called).to be false
      end

      it "updates reconnect time from retry directive" do
        transport.send(:process_sse_line, "retry: 5000")
        expect(transport.instance_variable_get(:@reconnect_time)).to eq(5000)
      end

      it "handles invalid JSON gracefully" do
        handler_called = false
        transport.on_message { |_msg| handler_called = true }

        expect do
          transport.send(:process_sse_line, "data: invalid json")
        end.not_to raise_error

        expect(handler_called).to be false
      end
    end

    describe "#private_network_address?" do
      it "identifies localhost variants" do
        expect(transport.send(:private_network_address?, "localhost")).to be true
        expect(transport.send(:private_network_address?, "127.0.0.1")).to be true
        expect(transport.send(:private_network_address?, "::1")).to be true
      end

      it "identifies private IP ranges" do
        expect(transport.send(:private_network_address?, "192.168.1.1")).to be true
        expect(transport.send(:private_network_address?, "10.0.0.1")).to be true
        expect(transport.send(:private_network_address?, "172.16.0.1")).to be true
      end

      it "allows public addresses" do
        expect(transport.send(:private_network_address?, "8.8.8.8")).to be false
        expect(transport.send(:private_network_address?, "example.com")).to be false
      end
    end
  end
end
