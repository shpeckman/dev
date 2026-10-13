# src/dev/llm.cr
require "http/client"
require "json"

module Dev::LLM
  extend self

  ENDPOINT        = URI.parse("https://api.deepseek.com/chat/completions")
  KEY_ENV         = "DEEPSEEK_API_KEY"
  MODEL_ENV       = "PROJECT_LLM_MODEL"
  DEFAULT_MODEL   = "deepseek-flash"
  MAX_TOKENS      = 2048
  CONNECT_TIMEOUT = 10.seconds
  READ_TIMEOUT    = 90.seconds
  ERROR_PREVIEW   = 300

  class Failure < Exception
  end

  record Message, role : String, content : String do
    include JSON::Serializable
  end

  record Mode, type : String do
    include JSON::Serializable
  end

  record Request, model : String, messages : Array(Message), thinking : Mode,
    response_format : Mode, max_tokens : Int32, stream : Bool do
    include JSON::Serializable
  end

  struct Reply
    include JSON::Serializable

    getter content : String?
  end

  struct Choice
    include JSON::Serializable

    getter message : Reply
    getter finish_reason : String?
  end

  struct Response
    include JSON::Serializable

    getter choices : Array(Choice)
  end

  def key : String?
    ENV[KEY_ENV]?.presence
  end

  def model : String
    ENV[MODEL_ENV]?.presence || DEFAULT_MODEL
  end

  def available? : Bool
    !key.nil? && STDIN.tty? && STDOUT.tty?
  end

  def complete(system : String, user : String) : String
    token   = key || raise Failure.new("#{KEY_ENV} is not set")
    request = Request.new(model, [Message.new("system", system), Message.new("user", user)],
      Mode.new("disabled"), Mode.new("json_object"), MAX_TOKENS, false)
    client = HTTP::Client.new(ENDPOINT)
    client.connect_timeout = CONNECT_TIMEOUT
    client.read_timeout = READ_TIMEOUT
    headers  = HTTP::Headers{"Authorization" => "Bearer #{token}", "Content-Type" => "application/json"}
    response = client.post(ENDPOINT.path, headers: headers, body: request.to_json)
    unless response.success?
      raise Failure.new("HTTP #{response.status_code}: #{response.body[0, ERROR_PREVIEW].strip}")
    end
    choice = Response.from_json(response.body).choices.first? || raise Failure.new("no choices in the response")
    raise Failure.new("response cut off (finish_reason: length)") if choice.finish_reason == "length"
    content = choice.message.content
    raise Failure.new("empty content") if content.nil? || content.blank?
    content
  rescue ex : IO::Error | OpenSSL::Error | JSON::ParseException
    raise Failure.new(ex.message || ex.class.name)
  ensure
    client.try &.close
  end
end
