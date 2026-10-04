# frozen_string_literal: true

# Test doubles shared by the archiver tests.
module StubHttp
  # Stands in for a Net::HTTP response. is_a? is driven by the status code so
  # the production code can keep using Net::HTTPSuccess/Net::HTTPRedirection
  # checks, exactly as the older http_get tests do.
  class Response
    attr_reader :code, :body

    def initialize(code, body = '', location = nil)
      @code = code.to_s
      @body = body
      @location = location
    end

    def is_a?(klass)
      case klass.name
      when 'Net::HTTPSuccess' then @code.start_with?('2')
      when 'Net::HTTPRedirection' then @code.start_with?('3')
      else super
      end
    end

    def [](key)
      key.downcase == 'location' ? @location : nil
    end

    def read_body(&block)
      block.call(@body) if @body
    end
  end

  # Replaces http_get with something that honours the same contract: it calls
  # the body handler and reports whether the body was consumed.
  def stub_http_get(archiver, &responder)
    calls = []
    archiver.define_singleton_method(:http_get) do |uri, read_timeout: 60, headers: {}, &body_handler|
      calls << { uri: uri, read_timeout: read_timeout, headers: headers }
      responder.call(uri, calls.size).tap do |response|
        body_handler&.call(response)
      end
    end
    calls
  end

  def query_params(uri)
    URI.decode_www_form(uri.query.to_s).to_h
  end
end
